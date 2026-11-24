// Lua 5.4 binary chunk reader. See lua54_chunk.hpp. The reader follows lundump.c of Lua 5.4.9 call by call, so
// the same chunks are accepted and refused, with the same messages.
#include "lua54_chunk.hpp"

#include <climits>
#include <cstring>

namespace lua54 {

namespace {

const char *const kOpNames[NUM_OPCODES] = {
    "MOVE",    "LOADI",    "LOADF",    "LOADK",    "LOADKX",    "LOADFALSE",
    "LFALSESKIP",    "LOADTRUE",    "LOADNIL",    "GETUPVAL",    "SETUPVAL",    "GETTABUP",
    "GETTABLE",    "GETI",    "GETFIELD",    "SETTABUP",    "SETTABLE",    "SETI",
    "SETFIELD",    "NEWTABLE",    "SELF",    "ADDI",    "ADDK",    "SUBK",
    "MULK",    "MODK",    "POWK",    "DIVK",    "IDIVK",    "BANDK",
    "BORK",    "BXORK",    "SHRI",    "SHLI",    "ADD",    "SUB",
    "MUL",    "MOD",    "POW",    "DIV",    "IDIV",    "BAND",
    "BOR",    "BXOR",    "SHL",    "SHR",    "MMBIN",    "MMBINI",
    "MMBINK",    "UNM",    "BNOT",    "NOT",    "LEN",    "CONCAT",
    "CLOSE",    "TBC",    "JMP",    "EQ",    "LT",    "LE",
    "EQK",    "EQI",    "LTI",    "LEI",    "GTI",    "GEI",
    "TEST",    "TESTSET",    "CALL",    "TAILCALL",    "RETURN",    "RETURN0",
    "RETURN1",    "FORLOOP",    "FORPREP",    "TFORPREP",    "TFORCALL",    "TFORLOOP",
    "SETLIST",    "CLOSURE",    "VARARG",    "VARARGPREP",    "EXTRAARG",
};

const Fmt kOpFormats[NUM_OPCODES] = {
    Fmt::ABC,    Fmt::AsBx,    Fmt::AsBx,    Fmt::ABx,    Fmt::ABx,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::sJ,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,    Fmt::ABC,
    Fmt::ABC,    Fmt::ABx,    Fmt::ABx,    Fmt::ABx,    Fmt::ABC,    Fmt::ABx,    Fmt::ABC,    Fmt::ABx,
    Fmt::ABC,    Fmt::ABC,    Fmt::Ax,
};

// lobject.h: makevariant(type, variant) = type | variant << 4.
constexpr std::uint8_t kTagNil = 0x00, kTagFalse = 0x01, kTagTrue = 0x11, kTagInt = 0x03, kTagFloat = 0x13,
                       kTagShortStr = 0x04, kTagLongStr = 0x14;

// lundump.h
constexpr std::uint8_t kLuacVersion = 0x54;   // (5 * 16) + 4
constexpr std::uint8_t kLuacFormat = 0;
constexpr char kLuacData[] = "\x19\x93\r\n\x1a\n";
constexpr std::int64_t kLuacInt = 0x5678;
constexpr double kLuacNum = 370.5;

class Reader {
 public:
  Reader(const std::uint8_t *data, std::size_t size, const std::string &name) : p_(data), n_(size), name_(name) {}

  [[noreturn]] void error(const char *why) const {
    throw std::runtime_error(name_ + ": bad binary format (" + why + ")");
  }

  std::uint8_t byte() {
    if (pos_ >= n_) error("truncated chunk");
    return p_[pos_++];
  }

  void block(void *dst, std::size_t size) {
    if (size > n_ - pos_) error("truncated chunk");
    std::memcpy(dst, p_ + pos_, size);
    pos_ += size;
  }

  // loadUnsigned: 7 bits per byte, most significant first; the byte with bit 7 set ends the number.
  std::size_t unsigned_(std::size_t limit) {
    std::size_t x = 0;
    int b;
    limit >>= 7;
    do {
      b = byte();
      if (x >= limit) error("integer overflow");
      x = (x << 7) | static_cast<std::size_t>(b & 0x7f);
    } while ((b & 0x80) == 0);
    return x;
  }

  int int_() { return static_cast<int>(unsigned_(INT_MAX)); }

  // Native-width values are stored little-endian here; the LUAC_INT and LUAC_NUM checks make a mismatch fail.
  std::uint64_t fixed64() {
    std::uint8_t b[8];
    block(b, 8);
    std::uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | b[i];
    return v;
  }

  // loadStringN: a size of 0 is "no string"; otherwise the size includes one extra byte.
  std::optional<std::string> string_n() {
    std::size_t size = unsigned_(static_cast<std::size_t>(-1));
    if (size == 0) return std::nullopt;
    --size;
    std::string s(size, '\0');
    if (size > 0) block(&s[0], size);
    return s;
  }

  void expect_literal(const char *s, std::size_t len, const char *msg) {
    for (std::size_t i = 0; i < len; ++i)
      if (byte() != static_cast<std::uint8_t>(s[i])) error(msg);
  }

  void check_size(std::uint8_t want, const char *what) {
    if (byte() != want) {
      throw std::runtime_error(name_ + ": bad binary format (" + what + " size mismatch)");
    }
  }

 private:
  const std::uint8_t *p_;
  std::size_t n_;
  std::size_t pos_ = 0;
  std::string name_;
};

void load_function(Reader &r, Proto &f) {
  f.source = r.string_n();
  f.linedefined = r.int_();
  f.lastlinedefined = r.int_();
  f.numparams = r.byte();
  f.is_vararg = r.byte() != 0;
  f.maxstacksize = r.byte();

  // loadCode
  int n = r.int_();
  f.code.resize(static_cast<std::size_t>(n));
  for (auto &insn : f.code) {
    std::uint8_t b[4];
    r.block(b, 4);
    insn.raw = static_cast<std::uint32_t>(b[0]) | static_cast<std::uint32_t>(b[1]) << 8 |
               static_cast<std::uint32_t>(b[2]) << 16 | static_cast<std::uint32_t>(b[3]) << 24;
  }

  // loadConstants
  n = r.int_();
  f.k.resize(static_cast<std::size_t>(n));
  for (auto &c : f.k) {
    switch (r.byte()) {
      case kTagNil: c.kind = Constant::Kind::Nil; break;
      case kTagFalse: c.kind = Constant::Kind::False; break;
      case kTagTrue: c.kind = Constant::Kind::True; break;
      case kTagFloat: {
        std::uint64_t bits = r.fixed64();
        std::memcpy(&c.f, &bits, sizeof c.f);
        c.kind = Constant::Kind::Float;
        break;
      }
      case kTagInt:
        c.i = static_cast<std::int64_t>(r.fixed64());
        c.kind = Constant::Kind::Integer;
        break;
      case kTagShortStr:
      case kTagLongStr: {
        auto s = r.string_n();
        if (!s) r.error("bad format for constant string");
        c.s = *s;
        c.kind = Constant::Kind::String;
        break;
      }
      default: r.error("bad constant type");
    }
  }

  // loadUpvalues
  n = r.int_();
  f.upvalues.resize(static_cast<std::size_t>(n));
  for (auto &u : f.upvalues) {
    u.instack = r.byte();
    u.idx = r.byte();
    u.kind = r.byte();
  }

  // loadProtos
  n = r.int_();
  f.p.reserve(static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i) {
    f.p.push_back(std::make_unique<Proto>());
    load_function(r, *f.p.back());
  }

  // loadDebug
  n = r.int_();
  f.lineinfo.resize(static_cast<std::size_t>(n));
  if (n > 0) r.block(f.lineinfo.data(), static_cast<std::size_t>(n));
  n = r.int_();
  f.abslineinfo.resize(static_cast<std::size_t>(n));
  for (auto &a : f.abslineinfo) {
    a.pc = r.int_();
    a.line = r.int_();
  }
  n = r.int_();
  f.locvars.resize(static_cast<std::size_t>(n));
  for (auto &lv : f.locvars) {
    lv.name = r.string_n();
    lv.startpc = r.int_();
    lv.endpc = r.int_();
  }
  // A stripped chunk writes 0 here; otherwise there is one name per upvalue (lundump.c).
  n = r.int_();
  if (n != 0) n = static_cast<int>(f.upvalues.size());
  for (int i = 0; i < n; ++i) f.upvalues[static_cast<std::size_t>(i)].name = r.string_n();
}

}  // namespace

const char *op_name(std::uint8_t op) { return op < NUM_OPCODES ? kOpNames[op] : "?"; }

Fmt op_format(std::uint8_t op) { return kOpFormats[op < NUM_OPCODES ? op : 0]; }

Chunk load(const std::uint8_t *data, std::size_t size, const std::string &name) {
  Reader r(data, size, name);
  // checkHeader: the signature's first byte is checked by the caller in lundump.c; here all four bytes.
  r.expect_literal("\x1bLua", 4, "not a binary chunk");
  if (r.byte() != kLuacVersion) r.error("version mismatch");
  if (r.byte() != kLuacFormat) r.error("format mismatch");
  r.expect_literal(kLuacData, sizeof kLuacData - 1, "corrupted chunk");
  r.check_size(4, "Instruction");
  r.check_size(8, "lua_Integer");
  r.check_size(8, "lua_Number");
  // loadInteger / loadNumber: the test values, read back from their 8-byte encodings.
  Chunk chunk;
  {
    std::uint64_t v = 0;
    std::uint8_t b[8];
    r.block(b, 8);
    for (int i = 7; i >= 0; --i) v = (v << 8) | b[i];
    if (static_cast<std::int64_t>(v) != kLuacInt) r.error("integer format mismatch");
  }
  {
    std::uint8_t b[8];
    r.block(b, 8);
    std::uint64_t bits = 0;
    for (int i = 7; i >= 0; --i) bits = (bits << 8) | b[i];
    double d;
    std::memcpy(&d, &bits, sizeof d);
    if (d != kLuacNum) r.error("float format mismatch");
  }
  chunk.upvalue_count = r.byte();
  chunk.main = std::make_unique<Proto>();
  load_function(r, *chunk.main);
  return chunk;
}

}  // namespace lua54
