// mruby RITE 04.00 reader (mrb_rite.hpp). Layouts: mruby 4.0.0 src/dump.c (writer) and src/load.c (reader).
#include "mrb_rite.hpp"

#include <cstring>

namespace mrb {

namespace {

struct OpDesc {
  const char *name;
  const char *fmt;
};

const OpDesc kOps[] = {
#define OPCODE(name, fmt) {#name, #fmt},
#include "mrb_opcodes.inc"
#undef OPCODE
};

constexpr int kNumOps = static_cast<int>(sizeof(kOps) / sizeof(kOps[0]));
static_assert(kNumOps == NUM_OPCODES, "mrb_opcodes.inc and the Opcode enum disagree");

constexpr std::uint8_t kPoolStr = 0, kPoolInt32 = 1, kPoolInt64 = 3, kPoolFloat = 5, kPoolBigInt = 7;
constexpr std::uint16_t kNullSym = 0xFFFF;
constexpr std::uint32_t kCatchSize = 13;  // struct mrb_irep_catch_handler: u8 + 3 x u32

// A bounds-checked cursor over the file. Every read names what it reads, so a truncated file says where.
struct Reader {
  const std::uint8_t *d;
  std::size_t n;
  std::size_t p = 0;

  void need(std::size_t k, const char *what) const {
    if (p > n || k > n - p) {
      throw ReadError(std::string("truncated ") + what + " at byte " + std::to_string(p));
    }
  }
  std::uint8_t u8(const char *what) {
    need(1, what);
    return d[p++];
  }
  std::uint16_t u16(const char *what) {
    need(2, what);
    std::uint16_t v = static_cast<std::uint16_t>((d[p] << 8) | d[p + 1]);
    p += 2;
    return v;
  }
  std::uint32_t u32(const char *what) {
    need(4, what);
    std::uint32_t v = (static_cast<std::uint32_t>(d[p]) << 24) | (static_cast<std::uint32_t>(d[p + 1]) << 16) |
                      (static_cast<std::uint32_t>(d[p + 2]) << 8) | d[p + 3];
    p += 4;
    return v;
  }
  // A NUL-terminated string of len bytes followed by its NUL (pool strings and symbol names).
  std::string cstr(std::size_t len, const char *what) {
    need(len + 1, what);
    if (d[p + len] != 0) throw ReadError(std::string(what) + " at byte " + std::to_string(p) + " is not NUL-terminated");
    std::string s(reinterpret_cast<const char *>(d + p), len);
    p += len + 1;
    return s;
  }
};

// The operand widths of an opcode format under an EXT prefix: the FETCH_<fmt>_<ext> macros of ops.h.
std::vector<int> widths_for(const std::string &fmt, int ext) {
  if (fmt == "Z") return {};
  if (fmt == "W") return {24};
  if (fmt == "S") return {16};
  if (fmt == "B") return {ext == 1 ? 16 : 8};
  if (fmt == "BB") {
    switch (ext) {
      case 1: return {16, 8};
      case 2: return {8, 16};
      case 3: return {16, 16};
      default: return {8, 8};
    }
  }
  if (fmt == "BBB") {
    switch (ext) {
      case 1: return {16, 8, 8};
      case 2: return {8, 16, 8};
      case 3: return {16, 16, 8};
      default: return {8, 8, 8};
    }
  }
  if (fmt == "BS") {
    switch (ext) {
      case 1: return {16, 16};
      case 2: return {8, 16};
      case 3: return {16, 16};
      default: return {8, 16};
    }
  }
  if (fmt == "BSS") {
    switch (ext) {
      case 1: return {16, 16, 16};
      case 2: return {8, 16, 16};
      case 3: return {16, 16, 16};
      default: return {8, 16, 16};
    }
  }
  throw ReadError("unknown operand format " + fmt);
}

// One irep record (dump.c's write_irep_record without the children; the children follow it). The record size field
// counts the header, iseq, pool and symbol blocks only.
Irep read_record(Reader &r, int depth) {
  if (depth > 512) throw ReadError("irep nesting deeper than 512");
  const std::size_t start = r.p;
  const std::uint32_t rec_size = r.u32("irep record size");
  Irep irep;
  irep.nlocals = r.u16("nlocals");
  irep.nregs = r.u16("nregs");
  const std::uint16_t rlen = r.u16("child count");

  const std::uint16_t clen = r.u16("catch count");
  const std::uint32_t ilen = r.u32("iseq length");
  r.need(static_cast<std::size_t>(ilen), "iseq");
  irep.iseq.assign(r.d + r.p, r.d + r.p + ilen);
  r.p += ilen;
  r.need(static_cast<std::size_t>(clen) * kCatchSize, "catch table");
  for (std::uint16_t i = 0; i < clen; ++i) {
    Catch c;
    c.type = r.u8("catch type");
    c.begin = r.u32("catch begin");
    c.end = r.u32("catch end");
    c.target = r.u32("catch target");
    irep.catches.push_back(c);
  }

  const std::uint16_t plen = r.u16("pool count");
  for (std::uint16_t i = 0; i < plen; ++i) {
    Pool pv;
    const std::uint8_t tt = r.u8("pool type");
    switch (tt) {
      case kPoolInt32:
        pv.kind = Pool::Kind::Int;
        pv.i = static_cast<std::int32_t>(r.u32("pool int32"));
        break;
      case kPoolInt64: {
        std::uint64_t hi = r.u32("pool int64 high");
        std::uint64_t lo = r.u32("pool int64 low");
        pv.kind = Pool::Kind::Int;
        pv.i = static_cast<std::int64_t>((hi << 32) | lo);
        break;
      }
      case kPoolFloat: {
        r.need(8, "pool float");
        unsigned char bits[8];
        for (int k = 0; k < 8; ++k) bits[k] = r.d[r.p + k];  // little-endian, as dump.c writes it
        r.p += 8;
        double f;
        std::memcpy(&f, bits, sizeof f);
        pv.kind = Pool::Kind::Float;
        pv.f = f;
        break;
      }
      case kPoolBigInt: {
        // The record is the length byte, a sign byte and `length` bytes of magnitude (dump.c writes length + 2 bytes).
        const std::uint8_t len = r.u8("bigint length");
        r.need(static_cast<std::size_t>(len) + 1, "bigint");
        pv.kind = Pool::Kind::BigInt;
        pv.s.assign(1, static_cast<char>(len));
        pv.s.append(reinterpret_cast<const char *>(r.d + r.p), static_cast<std::size_t>(len) + 1);
        r.p += static_cast<std::size_t>(len) + 1;
        break;
      }
      case kPoolStr: {
        const std::uint16_t len = r.u16("pool string length");
        pv.kind = Pool::Kind::Str;
        pv.s = r.cstr(len, "pool string");
        break;
      }
      default:
        throw ReadError("unknown pool type " + std::to_string(tt) + " at byte " + std::to_string(r.p - 1));
    }
    irep.pool.push_back(pv);
  }

  const std::uint16_t slen = r.u16("symbol count");
  for (std::uint16_t i = 0; i < slen; ++i) {
    const std::uint16_t snl = r.u16("symbol length");
    if (snl == kNullSym) {
      irep.syms.emplace_back();
      irep.sym_null.push_back(true);
      continue;
    }
    irep.syms.push_back(r.cstr(snl, "symbol name"));
    irep.sym_null.push_back(false);
  }

  if (r.p - start != rec_size) {
    throw ReadError("irep record at byte " + std::to_string(start) + " has size " + std::to_string(rec_size) +
                    ", its blocks take " + std::to_string(r.p - start));
  }

  for (std::uint16_t i = 0; i < rlen; ++i) irep.reps.push_back(read_record(r, depth + 1));
  return irep;
}

// The DBG section's record of one irep and its children (load.c's read_debug_record). Its contents are checked and
// dropped: the producer does not use line information yet.
void skip_debug_record(Reader &r, Irep &irep, std::size_t flen_names, int depth) {
  if (depth > 512) throw ReadError("DBG nesting deeper than 512");
  const std::size_t start = r.p;
  const std::uint32_t rec_size = r.u32("DBG record size");
  const std::uint16_t flen = r.u16("DBG file count");
  for (std::uint16_t f = 0; f < flen; ++f) {
    r.u32("DBG start position");
    const std::uint16_t name = r.u16("DBG file name index");
    if (name >= flen_names) throw ReadError("DBG file name index " + std::to_string(name) + " out of range");
    const std::uint32_t count = r.u32("DBG line entry count");
    const std::uint8_t type = r.u8("DBG line type");
    switch (type) {
      case 0: r.need(static_cast<std::size_t>(count) * 2, "DBG line array"); r.p += static_cast<std::size_t>(count) * 2; break;
      case 1: r.need(static_cast<std::size_t>(count) * 6, "DBG line flat map"); r.p += static_cast<std::size_t>(count) * 6; break;
      case 2: r.need(count, "DBG packed line map"); r.p += count; break;
      default: throw ReadError("unknown DBG line type " + std::to_string(type));
    }
  }
  if (r.p - start != rec_size) throw ReadError("DBG record size mismatch");
  irep.has_dbg = true;
  for (auto &child : irep.reps) skip_debug_record(r, child, flen_names, depth + 1);
}

// The LVAR section's names of one irep and its children (load.c's read_lv_record): nlocals - 1 symbol indices each,
// the root first, then the children in order.
void read_lv_record(Reader &r, Irep &irep, const std::vector<std::string> &syms, int depth) {
  if (depth > 512) throw ReadError("LVAR nesting deeper than 512");
  if (irep.nlocals == 0) throw ReadError("LVAR for an irep with no locals record");
  irep.has_lv = true;
  for (std::uint16_t i = 0; i + 1 < irep.nlocals; ++i) {
    const std::uint16_t idx = r.u16("LVAR index");
    if (idx == kNullSym) {
      irep.lv.emplace_back();
    } else {
      if (idx >= syms.size()) throw ReadError("LVAR symbol index " + std::to_string(idx) + " out of range");
      irep.lv.push_back(syms[idx]);
    }
  }
  for (auto &child : irep.reps) read_lv_record(r, child, syms, depth + 1);
}

}  // namespace

const char *op_name(int op) {
  return op >= 0 && op < kNumOps ? kOps[op].name : "?";
}

std::vector<int> operand_widths(int op, int ext) {
  if (op < 0 || op >= kNumOps) throw ReadError("unknown opcode " + std::to_string(op));
  return widths_for(kOps[op].fmt, ext);
}

Module read_module(const std::uint8_t *data, std::size_t size) {
  constexpr std::size_t kHeader = 20;  // struct rite_binary_header
  Reader r{data, size};
  r.need(kHeader, "binary header");
  if (std::memcmp(data, "RITE", 4) != 0) throw ReadError("not a RITE file (no RITE magic)");
  if (std::memcmp(data + 4, "04", 2) != 0 || std::memcmp(data + 6, "00", 2) != 0) {
    throw ReadError("RITE format " + std::string(reinterpret_cast<const char *>(data + 4), 4) +
                    " is not 04.00");
  }
  Module m;
  r.p = 8;  // ident[4], major[2], minor[2], then binary_size[4]
  m.binary_size = r.u32("binary size");
  if (m.binary_size != size) {
    throw ReadError("binary size field is " + std::to_string(m.binary_size) + ", the file has " + std::to_string(size) +
                    " bytes");
  }
  m.compiler.assign(reinterpret_cast<const char *>(data + 12), 4);
  m.compiler_version.assign(reinterpret_cast<const char *>(data + 16), 4);

  bool have_irep = false, have_end = false;
  std::vector<std::string> filenames;  // the DBG file table: read for its size, not kept
  r.p = kHeader;
  while (!have_end) {
    const std::size_t sec = r.p;
    r.need(8, "section header");
    const char *ident = reinterpret_cast<const char *>(data + sec);
    const std::uint32_t sec_size = (static_cast<std::uint32_t>(data[sec + 4]) << 24) |
                                   (static_cast<std::uint32_t>(data[sec + 5]) << 16) |
                                   (static_cast<std::uint32_t>(data[sec + 6]) << 8) | data[sec + 7];
    if (sec_size < 8 || sec_size > size - sec) {
      throw ReadError("section at byte " + std::to_string(sec) + " has size " + std::to_string(sec_size));
    }
    const std::size_t sec_end = sec + sec_size;
    if (std::memcmp(ident, "IREP", 4) == 0) {
      if (have_irep) throw ReadError("second IREP section at byte " + std::to_string(sec));
      if (std::memcmp(data + sec + 8, "0400", 4) != 0) throw ReadError("IREP section is not version 0400");
      r.p = sec + 12;
      m.root = read_record(r, 0);
      if (r.p != sec_end) throw ReadError("IREP section size does not match its records");
      have_irep = true;
    } else if (std::memcmp(ident, "DBG\0", 4) == 0) {
      if (!have_irep) throw ReadError("DBG section before IREP");
      r.p = sec + 8;
      const std::uint16_t names = r.u16("DBG file table count");
      for (std::uint16_t i = 0; i < names; ++i) {
        const std::uint16_t len = r.u16("DBG file name length");
        r.need(len, "DBG file name");
        filenames.emplace_back(reinterpret_cast<const char *>(data + r.p), len);
        r.p += len;
      }
      skip_debug_record(r, m.root, names, 0);
      if (r.p != sec_end) throw ReadError("DBG section size does not match its records");
    } else if (std::memcmp(ident, "LVAR", 4) == 0) {
      if (!have_irep) throw ReadError("LVAR section before IREP");
      r.p = sec + 8;
      const std::uint32_t syms_len = r.u32("LVAR symbol count");
      std::vector<std::string> syms;
      for (std::uint32_t i = 0; i < syms_len; ++i) {
        const std::uint16_t len = r.u16("LVAR symbol length");
        r.need(len, "LVAR symbol");
        syms.emplace_back(reinterpret_cast<const char *>(data + r.p), len);  // no NUL in LVAR names (dump.c)
        r.p += len;
      }
      read_lv_record(r, m.root, syms, 0);
      if (r.p != sec_end) throw ReadError("LVAR section size does not match its records");
    } else if (std::memcmp(ident, "END\0", 4) == 0) {
      if (sec_size != 8) throw ReadError("END section has size " + std::to_string(sec_size));
      if (sec_end != size) {
        throw ReadError(std::to_string(size - sec_end) + " bytes after the END section");
      }
      have_end = true;
    } else {
      throw ReadError("unknown section " + std::string(ident, 4) + " at byte " + std::to_string(sec));
    }
    r.p = sec_end;
  }
  if (!have_irep) throw ReadError("no IREP section");
  return m;
}

std::vector<Insn> decode_iseq(const Irep &irep) {
  std::vector<Insn> out;
  const std::vector<std::uint8_t> &code = irep.iseq;
  std::size_t pc = 0;
  int pending_ext = 0;  // the EXT prefix in front of the instruction being decoded
  while (pc < code.size()) {
    const int op = code[pc];
    if (op >= NUM_OPCODES) {
      throw ReadError("unknown opcode " + std::to_string(op) + " at pc " + std::to_string(pc));
    }
    const bool is_prefix = op == OP_EXT1 || op == OP_EXT2 || op == OP_EXT3;
    if (pending_ext != 0 && is_prefix) {
      throw ReadError("EXT prefix after an EXT prefix at pc " + std::to_string(pc));
    }
    if (is_prefix) {
      if (pc + 1 >= code.size()) throw ReadError("EXT prefix at the end of the iseq");
      Insn in;
      in.pc = pc;
      in.len = 1;
      in.op = op;
      in.name = op_name(op);
      out.push_back(in);
      pending_ext = op - OP_EXT1 + 1;
      pc += 1;
      continue;
    }
    Insn in;
    in.pc = pc;
    in.op = op;
    in.ext = pending_ext;
    in.name = op_name(op);
    std::size_t at = pc + 1;
    for (int w : widths_for(kOps[op].fmt, pending_ext)) {
      const std::size_t bytes = static_cast<std::size_t>(w) / 8;
      if (at + bytes > code.size()) {
        throw ReadError(std::string(in.name) + " at pc " + std::to_string(pc) + " runs past the end of the iseq");
      }
      std::uint32_t v = 0;
      for (std::size_t k = 0; k < bytes; ++k) v = (v << 8) | code[at + k];
      in.args.push_back(v);
      at += bytes;
    }
    in.len = at - pc;
    out.push_back(in);
    pc = at;
    pending_ext = 0;
  }
  if (pending_ext != 0) throw ReadError("EXT prefix not followed by an instruction");
  return out;
}

}  // namespace mrb
