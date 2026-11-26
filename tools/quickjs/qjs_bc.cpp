// The QuickJS bytecode reader (see qjs_bc.hpp). The order of the fields follows JS_ReadObjectAtoms, JS_ReadObjectRec and
// JS_ReadFunctionTag in 3rd/quickjs/quickjs.c.
#include "qjs_bc.hpp"

#include <cstring>
#include <stdexcept>

#include "qjs_tables.inc"   // kQjsBcVersion, kQjsOps, kQjsAtoms, kQjsAtomEnd

namespace qjs {

namespace {

// BC_TAG_* (quickjs.c): the tags a constant pool entry can carry.
constexpr int kTagNull = 1, kTagUndefined = 2, kTagBoolFalse = 3, kTagBoolTrue = 4, kTagInt32 = 5, kTagFloat64 = 6,
              kTagString = 7, kTagFunctionBytecode = 12;

[[noreturn]] void bad(const std::string &what, const char *prefix = "") {
  throw std::runtime_error(std::string(prefix) + what);
}

class Reader {
 public:
  Reader(const std::vector<std::uint8_t> &b) : b_(b) {}

  std::uint8_t u8() {
    need(1);
    return b_[p_++];
  }
  std::uint16_t u16() {
    need(2);
    std::uint16_t v = static_cast<std::uint16_t>(b_[p_] | (b_[p_ + 1] << 8));
    p_ += 2;
    return v;
  }
  std::uint64_t u64() {
    need(8);
    std::uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | b_[p_ + static_cast<std::size_t>(i)];
    p_ += 8;
    return v;
  }
  // dbuf_put_leb128: 7 bits per byte, least significant group first, bit 7 set on every byte but the last.
  std::uint32_t leb() {
    std::uint32_t v = 0;
    int shift = 0;
    for (;;) {
      std::uint8_t c = u8();
      if (shift >= 32) bad("leb128 value too long");
      v |= static_cast<std::uint32_t>(c & 0x7f) << shift;
      if (!(c & 0x80)) return v;
      shift += 7;
    }
  }
  // dbuf_put_sleb128: the same groups, the last one sign-extended from bit 6.
  std::int32_t sleb() {
    std::uint32_t v = 0;
    int shift = 0;
    std::uint8_t c;
    do {
      c = u8();
      if (shift >= 32) bad("sleb128 value too long");
      v |= static_cast<std::uint32_t>(c & 0x7f) << shift;
      shift += 7;
    } while (c & 0x80);
    if (shift < 32 && (c & 0x40)) v |= ~std::uint32_t{0} << shift;
    return static_cast<std::int32_t>(v);
  }
  std::string bytes(std::size_t n) {
    need(n);
    std::string s(reinterpret_cast<const char *>(&b_[p_]), n);
    p_ += n;
    return s;
  }
  std::size_t pos() const { return p_; }
  void need(std::size_t n) const {
    if (b_.size() - p_ < n) bad("truncated image at offset " + std::to_string(p_));
  }

 private:
  const std::vector<std::uint8_t> &b_;
  std::size_t p_ = 0;
};

// JS_ReadString: a leb128 of (length << 1 | wide), then the bytes (two per character when wide).
std::string read_string(Reader &r, bool &wide) {
  std::uint32_t v = r.leb();
  wide = (v & 1) != 0;
  std::size_t len = v >> 1;
  std::string s = r.bytes(len << (wide ? 1 : 0));
  return s;
}

// An atom in a vardef or closure var (bc_get_atom): a leb128 whose low bit tags an integer atom.
struct AtomRef {
  std::uint32_t number = 0;
  bool tagged_int = false;
};

AtomRef leb_atom(Reader &r) {
  std::uint32_t v = r.leb();
  AtomRef a;
  a.tagged_int = (v & 1) != 0;
  a.number = v >> 1;
  return a;
}

// JS_ReadObjectRec for a constant pool entry (any object of the image other than a function is refused here: the
// reader cannot skip an object it does not know the layout of, and no object constant is lowered).
void read_const(Reader &r, Bc &bc, std::vector<Const> &pool, std::size_t idx);

Fn read_function(Reader &r, Bc &bc);

}  // namespace

bool Bc::atom_name(std::uint32_t v, std::string &out) const {
  if (v & 0x80000000u) return false;   // a tagged integer atom (__JS_AtomIsTaggedInt)
  if (v < static_cast<std::uint32_t>(kQjsAtomEnd)) {
    out = kQjsAtoms[v];
    return true;
  }
  std::uint32_t idx = v - static_cast<std::uint32_t>(kQjsAtomEnd);
  if (idx >= user_atoms.size()) return false;
  out = user_atoms[idx];
  return true;
}

namespace {

void read_const(Reader &r, Bc &bc, std::vector<Const> &pool, std::size_t idx) {
  std::uint8_t tag = r.u8();
  Const c;
  switch (tag) {
    case kTagNull: c.kind = Const::Null; break;
    case kTagUndefined: c.kind = Const::Undefined; break;
    case kTagBoolFalse: c.kind = Const::Bool; c.i = 0; break;
    case kTagBoolTrue: c.kind = Const::Bool; c.i = 1; break;
    case kTagInt32: c.kind = Const::Int; c.i = r.sleb(); break;
    case kTagFloat64: {
      std::uint64_t bits = r.u64();
      std::memcpy(&c.d, &bits, sizeof c.d);
      c.kind = Const::Float;
      break;
    }
    case kTagString: {
      bool wide = false;
      c.s = read_string(r, wide);
      c.wide = wide;
      c.kind = Const::Str;
      break;
    }
    case kTagFunctionBytecode: {
      Fn f = read_function(r, bc);
      bc.fns.push_back(std::move(f));
      c.kind = Const::Func;
      c.i = static_cast<std::int32_t>(bc.fns.size() - 1);
      break;
    }
    default:
      bad("object constant (BC tag " + std::to_string(tag) + ") in the constant pool of a function", "refused: ");
  }
  pool.resize(idx + 1);
  pool[idx] = c;
}

// JS_ReadFunctionTag, after its tag byte.
Fn read_function(Reader &r, Bc &bc) {
  Fn f;
  std::uint16_t flags = r.u16();
  auto bit = [&](int n) { bool v = (flags >> n) & 1; return v; };
  f.has_prototype = bit(0);
  f.has_simple_parameter_list = bit(1);
  f.is_derived_class_constructor = bit(2);
  f.need_home_object = bit(3);
  f.func_kind = (flags >> 4) & 3;
  f.new_target_allowed = bit(6);
  f.super_call_allowed = bit(7);
  f.super_allowed = bit(8);
  f.arguments_allowed = bit(9);
  f.has_debug = bit(10);
  f.is_direct_or_indirect_eval = bit(11);
  f.js_mode = r.u8();
  AtomRef name = leb_atom(r);
  if (!name.tagged_int) bc.atom_name(name.number, f.name);
  f.arg_count = static_cast<int>(r.leb());
  f.var_count = static_cast<int>(r.leb());
  f.defined_arg_count = static_cast<int>(r.leb());
  f.stack_size = static_cast<int>(r.leb());
  f.var_ref_count = static_cast<int>(r.leb());
  std::uint32_t closure_var_count = r.leb();
  std::uint32_t cpool_count = r.leb();
  std::uint32_t byte_code_len = r.leb();
  std::uint32_t local_count = r.leb();
  if (closure_var_count > 65536 || cpool_count > 65536 || byte_code_len > (1u << 24) || local_count > 65536) {
    bad("malformed function header (counts out of range)");
  }
  for (std::uint32_t i = 0; i < local_count; ++i) {
    VarDef vd;
    AtomRef a = leb_atom(r);
    if (a.tagged_int || !bc.atom_name(a.number, vd.name)) bad("a local with an integer name");
    (void)r.leb();   // scope_next (the scope chain, not used)
    (void)r.leb();   // var_ref_idx
    std::uint8_t vf = r.u8();
    vd.var_kind = vf & 0xf;
    vd.is_const = (vf >> 4) & 1;
    vd.is_lexical = (vf >> 5) & 1;
    vd.is_captured = (vf >> 6) & 1;
    f.vardefs.push_back(vd);
  }
  for (std::uint32_t i = 0; i < closure_var_count; ++i) {
    ClosureVar cv;
    AtomRef a = leb_atom(r);
    if (a.tagged_int || !bc.atom_name(a.number, cv.name)) bad("a closure variable with an integer name");
    cv.var_idx = static_cast<int>(r.leb());
    std::uint16_t cf = r.u16();
    cv.closure_type = cf & 7;
    cv.is_const = (cf >> 3) & 1;
    cv.is_lexical = (cf >> 4) & 1;
    cv.var_kind = (cf >> 5) & 0xf;
    f.closure_vars.push_back(cv);
  }
  f.code.resize(byte_code_len);
  for (std::uint32_t i = 0; i < byte_code_len; ++i) f.code[i] = r.u8();
  if (f.has_debug) {
    (void)leb_atom(r);                        // filename
    std::uint32_t pc2line_len = r.leb();
    (void)r.bytes(pc2line_len);
    std::uint32_t source_len = r.leb();
    (void)r.bytes(source_len);
  }
  // The constants: a child function is appended to bc.fns while its index is still unknown here, so the constant's index
  // is the one it gets in the list, and the reader keeps the pool in order.
  for (std::uint32_t i = 0; i < cpool_count; ++i) read_const(r, bc, f.cpool, i);
  return f;
}

}  // namespace

Bc read_bc(const std::vector<std::uint8_t> &bytes) {
  Reader r(bytes);
  Bc bc;
  std::uint8_t version = r.u8();
  if (version != kQjsBcVersion) {
    bad("bytecode version " + std::to_string(version) + " (this producer reads version " + std::to_string(kQjsBcVersion) +
        ")", "refused: ");
  }
  std::uint32_t natoms = r.leb();
  for (std::uint32_t i = 0; i < natoms; ++i) {
    bool wide = false;
    std::string s = read_string(r, wide);
    if (wide) {
      // A 16-bit atom (a non-Latin-1 identifier): every code unit that is not ASCII becomes a byte the lowering's
      // identifier check refuses, so such a name is never lowered.
      std::string t;
      for (std::size_t k = 0; k + 1 < s.size(); k += 2) {
        unsigned c = static_cast<unsigned char>(s[k]) | (static_cast<unsigned>(static_cast<unsigned char>(s[k + 1])) << 8);
        t += c < 128 ? static_cast<char>(c) : '\x01';
      }
      s = t;
    }
    bc.user_atoms.push_back(s);
  }
  // The root object: a function (the top-level script). Any other object is refused by read_const.
  std::uint8_t tag = r.u8();
  if (tag != kTagFunctionBytecode) bad("the image is not a function (BC tag " + std::to_string(tag) + ")", "refused: ");
  Fn top = read_function(r, bc);
  bc.fns.insert(bc.fns.begin(), std::move(top));
  // Child functions were appended as they were read; the top-level function is fns[0] and the constant indices of the
  // children are the ones read before it was inserted, so they are shifted by one.
  for (auto &f : bc.fns) {
    for (auto &c : f.cpool) {
      if (c.kind == Const::Func) c.i += 1;
    }
  }
  if (r.pos() != bytes.size()) bad("trailing bytes after the image at offset " + std::to_string(r.pos()));
  return bc;
}

}  // namespace qjs
