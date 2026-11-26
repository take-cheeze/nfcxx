// Ruby 3.3 binary iseq reader (tools/yarvbc/yarv_ibf.hpp). Layouts follow Ruby 3.3.6's compile.c (ibf_dump_* and ibf_load_*):
// the header struct ibf_header, the object list (ibf_object_header and the per-type bodies), the small-value encoding, the
// iseq record (ibf_dump_iseq_each: 43 small values, then the tables at offsets relative to the record), the instruction
// stream (ibf_dump_code: an opcode, then its operands, where a CALL_DATA operand has no bytes in the stream) and the
// call-data table (ibf_dump_ci_entries).
#include "yarv_ibf.hpp"

#include <cstring>

namespace yarv {

namespace {

// The opcode names of Ruby 3.3 (index = opcode number).
#define YARV_OPCODE(name, number) #name,
const char *const kOpcodeNames[] = {
#include "yarv_insns.inc"
};
#undef YARV_OPCODE
constexpr std::size_t kOpcodeCount = sizeof(kOpcodeNames) / sizeof(kOpcodeNames[0]);

// The operand kinds of the instructions the reader decodes (the operand types of insns.def, as ibf_dump_code writes them):
//   'n'  a number written as is (a lindex, a level, or an OFFSET: the word offset of a jump target)
//   'v'  a value: an object index (TS_VALUE)
//   'i'  an id: an object index of a symbol (TS_ID)
//   'I'  an iseq: an iseq index written as a small value, -1 (all ones) for none (TS_ISEQ)
//   'c'  a call data: no bytes in the stream; it is the next entry of the iseq's call table (TS_CALLDATA)
struct OpSpec {
  const char *name;
  const char *kinds;
};

// The instructions the reader decodes. Any other instruction is refused by name.
constexpr OpSpec kSpecs[] = {
    {"nop", ""},
    {"getlocal_WC_0", "n"},
    {"setlocal_WC_0", "n"},
    {"getlocal_WC_1", "n"},
    {"setlocal_WC_1", "n"},
    {"putnil", ""},
    {"putself", ""},
    {"putobject", "v"},
    {"putobject_INT2FIX_0_", ""},
    {"putobject_INT2FIX_1_", ""},
    {"pop", ""},
    {"dup", ""},
    {"opt_plus", "c"},
    {"opt_minus", "c"},
    {"opt_mult", "c"},
    {"opt_div", "c"},
    {"opt_mod", "c"},
    {"opt_lt", "c"},
    {"opt_le", "c"},
    {"opt_gt", "c"},
    {"opt_ge", "c"},
    {"opt_eq", "c"},
    {"opt_neq", "cc"},
    {"opt_not", "c"},
    {"branchif", "n"},
    {"branchunless", "n"},
    {"jump", "n"},
    {"leave", ""},
    {"send", "cI"},
    {"opt_send_without_block", "c"},
    {"invokeblock", "c"},
    {"definemethod", "iI"},
};

const OpSpec *find_spec(const std::string &name) {
  for (const OpSpec &s : kSpecs) {
    if (name == s.name) return &s;
  }
  return nullptr;
}

// ibf_header (38 bytes): magic, major and minor version, size, extra size, the iseq list size, the global object list size,
// the iseq list offset, the global object list offset, the endian mark and the word size. Fields are little-endian.
constexpr std::size_t kHeaderSize = 38;
constexpr std::size_t kIseqFields = 43;  // the small values of an iseq record (ibf_dump_iseq_each)

class Reader {
 public:
  Reader(const std::uint8_t *data, std::size_t size) : buf_(data), size_(size) {}

  Module run() {
    if (size_ < kHeaderSize) throw ReadError("malformed: the file is shorter than the iseq header");
    if (std::memcmp(buf_, "YARB", 4) != 0) throw ReadError("malformed: the file does not start with YARB");
    const std::uint32_t major = u32(4), minor = u32(8);
    if (major != kFormatMajor || minor != kFormatMinor) {
      throw Refused("refused: iseq format " + std::to_string(major) + "." + std::to_string(minor) +
                    " is not Ruby 3.3's format " + std::to_string(kFormatMajor) + "." + std::to_string(kFormatMinor));
    }
    if (u32(12) != size_) throw ReadError("malformed: the header size does not match the file size");
    if (buf_[36] != 'l') throw Refused("refused: a big-endian iseq is not read (the producer is little-endian)");
    if (buf_[37] != 8) throw Refused("refused: an iseq of word size " + std::to_string(buf_[37]) + " is not read");

    Module m;
    m.minor = minor;
    const std::uint32_t niseq = u32(20), nobj = u32(24), iseq_off = u32(28), obj_off = u32(32);
    check(obj_off, 4ull * nobj, "the object list");
    check(iseq_off, 4ull * niseq, "the iseq list");
    if (nobj == 0) throw ReadError("malformed: the object list is empty (it holds nil at index 0)");

    // the objects first: the names of the iseqs and the calls are object indices
    m.objects.resize(nobj);
    m.objects[0].kind = Value::Kind::Nil;
    objects_ = &m.objects;
    for (std::uint32_t i = 1; i < nobj; ++i) m.objects[i] = read_object(u32(obj_off + 4 * i));

    m.iseqs.resize(niseq);
    for (std::uint32_t i = 0; i < niseq; ++i) read_iseq(m, i, u32(iseq_off + 4 * i));

    std::size_t roots = 0;
    std::vector<bool> named(m.iseqs.size(), false);
    for (const Iseq &is : m.iseqs) {
      for (std::int64_t c : is.children) named[static_cast<std::size_t>(c)] = true;
    }
    for (std::size_t i = 0; i < m.iseqs.size(); ++i) {
      if (!named[i]) {
        m.root = i;
        ++roots;
      }
    }
    if (roots != 1) throw ReadError("malformed: the iseq list has " + std::to_string(roots) + " roots, not one");
    return m;
  }

 private:
  const std::uint8_t *buf_;
  std::size_t size_;
  const std::vector<Value> *objects_ = nullptr;

  std::uint32_t u32(std::size_t at) const {
    check(at, 4, "a word");
    return static_cast<std::uint32_t>(buf_[at]) | static_cast<std::uint32_t>(buf_[at + 1]) << 8 |
           static_cast<std::uint32_t>(buf_[at + 2]) << 16 | static_cast<std::uint32_t>(buf_[at + 3]) << 24;
  }

  void check(std::uint64_t at, std::uint64_t n, const char *what) const {
    if (at > size_ || n > size_ - at) throw ReadError(std::string("malformed: ") + what + " runs past the end of the file");
  }

  // ibf_load_small_value: the count of bytes is set by the lowest set bit of the first byte (1 when it is odd, 9 when it is
  // zero); the value is the first byte's bits above that, then the rest of the bytes, big-endian.
  std::uint64_t small(std::size_t &pos) const {
    check(pos, 1, "a small value");
    const std::uint8_t c = buf_[pos];
    const std::size_t n = (c & 1) ? 1 : (c == 0 ? 9 : static_cast<std::size_t>(__builtin_ctz(c)) + 1);
    check(pos, n, "a small value");
    std::uint64_t x = (n == 9) ? 0 : (static_cast<std::uint64_t>(c) >> n);
    for (std::size_t i = 1; i < n; ++i) x = (x << 8) | buf_[pos + i];
    pos += n;
    return x;
  }

  // ibf_load_object: the header byte (type in bits 0-4, special in bit 5, frozen in 6, internal in 7), then the body.
  Value read_object(std::uint32_t at) const {
    check(at, 1, "an object");
    const std::uint8_t hdr = buf_[at];
    Value v;
    v.type = hdr & 0x1f;
    std::size_t pos = at + 1;
    if ((hdr >> 5) & 1) {  // a special constant: its VALUE (a fixnum has the low bit set)
      const std::uint64_t x = small(pos);
      if (x == 0x00) {
        v.kind = Value::Kind::False;
      } else if (x == 0x04) {
        v.kind = Value::Kind::Nil;
      } else if (x == 0x14) {
        v.kind = Value::Kind::True;
      } else if (x & 1) {
        v.kind = Value::Kind::Fixnum;
        v.i = static_cast<std::int64_t>(x) >> 1;
      }
      return v;
    }
    if (v.type == 0x14) {  // T_SYMBOL: the name as a string body
      v.kind = Value::Kind::Symbol;
      v.s = string_body(pos);
    } else if (v.type == 0x05) {  // T_STRING
      v.kind = Value::Kind::String;
      v.s = string_body(pos);
    } else if (v.type == 0x04) {  // T_FLOAT: a double, written aligned to 8 bytes
      v.kind = Value::Kind::Float;
      const std::size_t at8 = ((pos - 1) / 8 + 1) * 8;  // IBF_ALIGNED_OFFSET(8, pos)
      check(at8, 8, "a float");
      std::memcpy(&v.f, buf_ + at8, 8);
    }
    return v;
  }

  // The body of a string or symbol: the encoding index (not used here), the length and the bytes.
  std::string string_body(std::size_t &pos) const {
    (void)small(pos);
    const std::uint64_t len = small(pos);
    check(pos, len, "a string");
    std::string s(reinterpret_cast<const char *>(buf_ + pos), static_cast<std::size_t>(len));
    pos += static_cast<std::size_t>(len);
    return s;
  }

  // The name of an id (an object index of a symbol). Index 0 is no id.
  std::string id_name(std::uint64_t index) const {
    if (index == 0) return "";
    if (index >= objects_->size()) throw ReadError("malformed: object index " + std::to_string(index) + " is out of range");
    const Value &v = (*objects_)[static_cast<std::size_t>(index)];
    if (v.kind != Value::Kind::Symbol) throw ReadError("malformed: an id is not a symbol");
    return v.s;
  }

  // ibf_load_iseq_each: the 43 small values in the order ibf_dump_iseq_each writes them. The offsets stored in a record are
  // relative to the record: the offset is record - stored.
  void read_iseq(Module &m, std::uint32_t index, std::uint32_t rec) {
    Iseq &is = m.iseqs[index];
    std::size_t pos = rec;
    auto field = [&]() { return small(pos); };
    auto rel = [&]() { return static_cast<std::size_t>(rec - field()); };

    is.type = static_cast<IseqType>(field());                    // 1  type
    is.words = field();                                          // 2  iseq_size
    const std::size_t bytecode_at = rel();                       // 3  bytecode offset
    const std::uint64_t bytecode_size = field();                 // 4  bytecode size
    is.param_flags = field();                                    // 5  param flags
    (void)field();                                               // 6  param.size
    is.lead_num = field();                                       // 7  lead_num
    (void)field();                                               // 8  opt_num
    (void)field();                                               // 9  rest_start
    (void)field();                                               // 10 post_start
    (void)field();                                               // 11 post_num
    (void)field();                                               // 12 block_start
    (void)field();                                               // 13 opt table offset
    (void)field();                                               // 14 keyword offset
    (void)field();                                               // 15 path object
    (void)field();                                               // 16 base label
    const std::uint64_t label = field();                         // 17 label (a string object, not an id)
    if (label != 0 && label < m.objects.size() && m.objects[label].kind == Value::Kind::String) is.label = m.objects[label].s;
    for (int k = 18; k <= 23; ++k) (void)field();                // first line, node id, code location
    (void)field();                                               // 24 insns info body
    (void)field();                                               // 25 insns info positions
    (void)field();                                               // 26 insns info size
    const std::size_t local_at = rel();                          // 27 local table offset
    is.catch_count = field();                                    // 28 catch table size
    (void)rel();                                                 // 29 catch table offset
    (void)field();                                               // 30 parent iseq
    (void)field();                                               // 31 local iseq
    (void)field();                                               // 32 mandatory-only iseq
    const std::size_t ci_at = rel();                             // 33 call info offset
    (void)rel();                                                 // 34 outer variables offset
    (void)field();                                               // 35 variable flip count
    const std::uint64_t local_size = field();                    // 36 local table size
    for (int k = 37; k <= 40; ++k) (void)field();                // 37-40 ivc, icvarc, ise and ic sizes
    const std::uint64_t ci_size = field();                       // 41 ci size
    is.stack_max = field();                                      // 42 stack max
    (void)field();                                               // 43 builtin attrs

    read_locals(is, local_at, local_size);
    read_calls(is, ci_at, ci_size);
    read_code(m, is, bytecode_at, bytecode_size);
  }

  void read_locals(Iseq &is, std::size_t at, std::uint64_t n) const {
    for (std::uint64_t i = 0; i < n; ++i) {
      check(at + 8 * i, 8, "the local table");
      std::uint64_t id = 0;
      for (int b = 7; b >= 0; --b) id = (id << 8) | buf_[at + 8 * i + static_cast<std::size_t>(b)];
      is.locals.push_back(id_name(id));
    }
  }

  void read_calls(Iseq &is, std::size_t at, std::uint64_t n) const {
    std::size_t pos = at;
    for (std::uint64_t i = 0; i < n; ++i) {
      CallInfo ci;
      const std::uint64_t mid = small(pos);
      if (mid != ~0ull) {  // a NULL call info is written as -1 and nothing else
        ci.present = true;
        ci.mid = id_name(mid);
        ci.flag = small(pos);
        ci.argc = small(pos);
        ci.kwlen = small(pos);
        for (std::uint64_t k = 0; k < ci.kwlen; ++k) (void)small(pos);
      }
      is.calls.push_back(ci);
    }
  }

  // ibf_load_code: the instruction stream of bytecode_size bytes at bytecode_at.
  void read_code(const Module &m, Iseq &is, std::size_t at, std::uint64_t size) const {
    check(at, size, "the instruction stream");
    std::size_t pos = at;
    const std::size_t end = at + static_cast<std::size_t>(size);
    std::size_t words = 0, next_call = 0;
    while (pos < end) {
      Insn in;
      in.pc = words;
      const std::uint64_t op = small(pos);
      if (op >= kOpcodeCount) throw ReadError("malformed: opcode " + std::to_string(op) + " is not a Ruby 3.3 instruction");
      in.op = static_cast<int>(op);
      in.name = kOpcodeNames[op];
      const OpSpec *spec = find_spec(in.name);
      if (spec == nullptr) {
        throw Refused("refused: instruction " + in.name + " is not lowered yet (pc " + std::to_string(words) + ")");
      }
      for (const char *k = spec->kinds; *k != '\0'; ++k) {
        if (*k == 'c') {
          // the call table's next entry (ibf_load_code's cd_entries++)
          if (next_call >= is.calls.size()) throw ReadError("malformed: more call operands than call info entries");
          in.operands.push_back(next_call++);
        } else if (*k == 'I') {
          const std::uint64_t child = small(pos);
          if (child != ~0ull) {
            if (child >= m.iseqs.size()) throw ReadError("malformed: iseq index " + std::to_string(child) + " is out of range");
            is.children.push_back(static_cast<std::int64_t>(child));
          }
          in.operands.push_back(child);
        } else {
          in.operands.push_back(small(pos));
        }
      }
      in.len = 1 + std::strlen(spec->kinds);
      words += in.len;
      is.insns.push_back(std::move(in));
    }
    if (words != is.words) {
      throw ReadError("malformed: the instruction stream is " + std::to_string(words) + " words, the iseq says " +
                      std::to_string(is.words));
    }
  }
};

}  // namespace

const Value &Module::object(std::uint64_t index) const {
  if (index >= objects.size()) throw ReadError("malformed: object index " + std::to_string(index) + " is out of range");
  return objects[static_cast<std::size_t>(index)];
}

Module read_module(const std::uint8_t *data, std::size_t size) {
  Reader r(data, size);
  return r.run();
}

}  // namespace yarv
