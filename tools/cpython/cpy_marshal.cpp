// CPython 3.13 .pyc reader (see cpy_marshal.hpp). The object stream is marshal.c's version 5 format: a type byte whose high
// bit (FLAG_REF) says the object is entered in the reference table, and TYPE_REF's index names an earlier entry. The entry
// of a flagged object is reserved before its contents are read, so a code object's references come out as in CPython.
#include "cpy_marshal.hpp"

#include <cstddef>
#include <stdexcept>

namespace cpy {

namespace {

constexpr std::uint8_t kFlagRef = 0x80;
constexpr int kMaxDepth = 200;
constexpr std::uint8_t kMagic[4] = {0xf3, 0x0d, 0x0d, 0x0a};   // importlib.util.MAGIC_NUMBER of CPython 3.13 (3571)

[[noreturn]] void refuse(const std::string &what) { throw std::runtime_error("refused: " + what); }

class Reader {
 public:
  Reader(const std::vector<std::uint8_t> &bytes, std::size_t pos) : b_(bytes), pos_(pos) {}

  ObjPtr object(int depth) {
    if (depth > kMaxDepth) refuse("pyc nests objects deeper than " + std::to_string(kMaxDepth));
    std::uint8_t code = byte();
    bool flag = (code & kFlagRef) != 0;
    char type = static_cast<char>(code & ~kFlagRef);
    if (type == 'r') {
      std::int64_t idx = long32();
      if (idx < 0 || static_cast<std::size_t>(idx) >= refs_.size()) refuse("pyc reference to an unknown object");
      return refs_[static_cast<std::size_t>(idx)];
    }
    auto o = std::make_shared<Obj>();
    if (flag) refs_.push_back(o);   // reserved before the contents, as marshal.c does for containers and code
    switch (type) {
      case '0': throw std::runtime_error("pyc: marshal NULL object");
      case 'N': o->kind = Obj::Kind::None; break;
      case 'F': o->kind = Obj::Kind::False; break;
      case 'T': o->kind = Obj::Kind::True; break;
      case '.': o->kind = Obj::Kind::Ellipsis; break;
      case 'S': o->other = 'S'; break;
      case 'i': o->kind = Obj::Kind::Int; o->i = long32(); break;
      case 'I': o->kind = Obj::Kind::Int; o->i = static_cast<std::int64_t>(long64()); break;
      case 'l': long_digits(*o); break;
      case 'g': skip(8); o->other = 'g'; break;                       // binary float
      case 'f': skip(byte()); o->other = 'f'; break;                  // text float
      case 'y': skip(16); o->other = 'y'; break;                      // binary complex
      case 'x': skip(byte()); skip(byte()); o->other = 'x'; break;    // text complex
      case 's': o->kind = Obj::Kind::Bytes; o->s = bytes(long32()); break;
      case 'a': case 'A': case 'u': case 't': o->kind = Obj::Kind::Str; o->s = bytes(long32()); break;
      case 'z': case 'Z': o->kind = Obj::Kind::Str; o->s = bytes(byte()); break;
      case '(': {
        o->kind = Obj::Kind::Tuple;
        std::int32_t n = long32();
        for (std::int32_t k = 0; k < n; ++k) o->items.push_back(object(depth + 1));
        break;
      }
      case ')': {
        o->kind = Obj::Kind::Tuple;
        std::uint8_t n = byte();
        for (std::uint8_t k = 0; k < n; ++k) o->items.push_back(object(depth + 1));
        break;
      }
      case 'c': o->kind = Obj::Kind::Code; o->code = code_object(depth + 1); break;
      case '[': case '{': case '<': case '>': case ':':
        refuse(std::string("marshal ") + type + " object (list, dict, set or slice) in the pyc is not decoded");
      default:
        throw std::runtime_error(std::string("pyc: unknown marshal type code '") + type + "'");
    }
    return o;
  }

  std::size_t pos() const { return pos_; }
  std::size_t size() const { return b_.size(); }

 private:
  const std::vector<std::uint8_t> &b_;
  std::size_t pos_;
  std::vector<ObjPtr> refs_;

  std::uint8_t byte() {
    if (pos_ >= b_.size()) throw std::runtime_error("pyc: truncated marshal data");
    return b_[pos_++];
  }
  void skip(std::size_t n) {
    if (n > b_.size() - pos_) throw std::runtime_error("pyc: truncated marshal data");
    pos_ += n;
  }
  std::string bytes(std::int64_t n) {
    if (n < 0 || static_cast<std::uint64_t>(n) > b_.size() - pos_) throw std::runtime_error("pyc: truncated marshal data");
    std::string s(b_.begin() + static_cast<std::ptrdiff_t>(pos_), b_.begin() + static_cast<std::ptrdiff_t>(pos_ + static_cast<std::size_t>(n)));
    pos_ += static_cast<std::size_t>(n);
    return s;
  }
  std::uint64_t le(std::size_t n) {
    std::uint64_t v = 0;
    for (std::size_t k = 0; k < n; ++k) v |= static_cast<std::uint64_t>(byte()) << (8 * k);
    return v;
  }
  std::int32_t long32() { return static_cast<std::int32_t>(static_cast<std::uint32_t>(le(4))); }
  std::int64_t long64() { return static_cast<std::int64_t>(le(8)); }

  // TYPE_LONG: a signed count of 15-bit digits, least significant first. Values wider than 62 bits are marked `big`.
  void long_digits(Obj &o) {
    std::int32_t n = long32();
    std::uint32_t count = n < 0 ? static_cast<std::uint32_t>(-static_cast<std::int64_t>(n)) : static_cast<std::uint32_t>(n);
    std::uint64_t value = 0;
    bool big = false;
    for (std::uint32_t i = 0; i < count; ++i) {
      std::uint64_t digit = le(2);
      unsigned shift = 15 * i;
      if (digit == 0) continue;
      if (shift >= 62 || (digit >> (62 - shift)) != 0) {
        big = true;   // digit << shift would reach bit 62
      } else {
        value |= digit << shift;
      }
    }
    if (big || value >> 62) {
      o.kind = Obj::Kind::Int;
      o.big = true;
      return;
    }
    o.kind = Obj::Kind::Int;
    o.i = n < 0 ? -static_cast<std::int64_t>(value) : static_cast<std::int64_t>(value);
  }

  std::shared_ptr<Code> code_object(int depth) {
    auto c = std::make_shared<Code>();
    c->argcount = long32();
    c->posonlyargcount = long32();
    c->kwonlyargcount = long32();
    c->stacksize = long32();
    c->flags = long32();
    ObjPtr co_code = object(depth);
    ObjPtr consts = object(depth);
    ObjPtr names = object(depth);
    ObjPtr localsplusnames = object(depth);
    ObjPtr localspluskinds = object(depth);
    ObjPtr filename = object(depth);
    ObjPtr name = object(depth);
    ObjPtr qualname = object(depth);
    (void)long32();                 // co_firstlineno
    ObjPtr linetable = object(depth);
    ObjPtr exctable = object(depth);
    if (co_code->kind != Obj::Kind::Bytes || consts->kind != Obj::Kind::Tuple || names->kind != Obj::Kind::Tuple ||
        localsplusnames->kind != Obj::Kind::Tuple || localspluskinds->kind != Obj::Kind::Bytes ||
        name->kind != Obj::Kind::Str || qualname->kind != Obj::Kind::Str || filename->kind != Obj::Kind::Str ||
        linetable->kind != Obj::Kind::Bytes || exctable->kind != Obj::Kind::Bytes) {
      throw std::runtime_error("pyc: malformed code object");
    }
    c->code = co_code->s;
    c->consts = consts->items;
    for (const ObjPtr &n : names->items) {
      if (n->kind != Obj::Kind::Str) throw std::runtime_error("pyc: a co_names item is not a str");
      c->names.push_back(n->s);
    }
    for (const ObjPtr &n : localsplusnames->items) {
      if (n->kind != Obj::Kind::Str) throw std::runtime_error("pyc: a co_localsplusnames item is not a str");
      c->localsplusnames.push_back(n->s);
    }
    c->localspluskinds = localspluskinds->s;
    c->name = name->s;
    c->qualname = qualname->s;
    c->filename = filename->s;
    c->exctable = exctable->s;
    return c;
  }
};

}  // namespace

Pyc load_pyc(const std::vector<std::uint8_t> &bytes) {
  if (bytes.size() < 16) refuse("the file is shorter than a .pyc header");
  for (int k = 0; k < 4; ++k) {
    if (bytes[static_cast<std::size_t>(k)] != kMagic[k]) {
      refuse("not a CPython 3.13 .pyc (magic bytes differ from importlib's MAGIC_NUMBER of 3.13)");
    }
  }
  std::uint32_t flags = static_cast<std::uint32_t>(bytes[4]) | (static_cast<std::uint32_t>(bytes[5]) << 8) |
                        (static_cast<std::uint32_t>(bytes[6]) << 16) | (static_cast<std::uint32_t>(bytes[7]) << 24);
  if (flags != 0) refuse("hash-based .pyc (flags " + std::to_string(flags) + ") is not lowered yet; compile with timestamps");
  Reader r(bytes, 16);
  ObjPtr top = r.object(0);
  if (top->kind != Obj::Kind::Code) refuse("the .pyc does not hold a code object at the top level");
  if (r.pos() != r.size()) refuse("trailing bytes after the module's code object");
  return Pyc{top->code};
}

}  // namespace cpy
