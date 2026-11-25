// MicroPython .mpy reader. See mpy_reader.hpp; the decoding mirrors py/persistentcode.c and py/bc.h of v1.29.0.
#include "mpy_reader.hpp"

#include <stdexcept>

#include "mpy_qstrs_static.inc"

namespace mpy {

namespace {

constexpr unsigned kMpyVersion = 6;
constexpr size_t kStaticQstrCount = sizeof(kStaticQstrs) / sizeof(kStaticQstrs[0]);

// persistentcode.h: MP_PERSISTENT_OBJ_*
enum : uint8_t {
  OBJ_FUN_TABLE = 0,
  OBJ_NONE,
  OBJ_FALSE,
  OBJ_TRUE,
  OBJ_ELLIPSIS,
  OBJ_STR,
  OBJ_BYTES,
  OBJ_INT,
  OBJ_FLOAT,
  OBJ_COMPLEX,
  OBJ_TUPLE,
};

class Reader {
 public:
  Reader(const uint8_t *p, size_t n) : p_(p), n_(n) {}

  uint8_t byte() {
    if (pos_ >= n_) throw std::runtime_error("mpy: truncated file");
    return p_[pos_++];
  }

  // read_uint of persistentcode.c: 7 bits per byte, most significant first, the last byte has bit 7 clear.
  size_t uint() {
    size_t u = 0;
    for (;;) {
      uint8_t b = byte();
      u = (u << 7) | (b & 0x7f);
      if ((b & 0x80) == 0) break;
    }
    return u;
  }

  std::vector<uint8_t> vec(size_t len) {
    if (len > n_ - pos_) throw std::runtime_error("mpy: truncated file");
    std::vector<uint8_t> v(p_ + pos_, p_ + pos_ + len);
    pos_ += len;
    return v;
  }

  std::string str(size_t len) {
    std::vector<uint8_t> v = vec(len);
    return std::string(v.begin(), v.end());
  }

  size_t pos() const { return pos_; }
  size_t size() const { return n_; }

 private:
  const uint8_t *p_;
  size_t n_;
  size_t pos_ = 0;
};

// load_qstr: an odd length marks a static qstr, whose value is its index in the built-in table.
std::string load_qstr(Reader &r) {
  size_t len = r.uint();
  if (len & 1) {
    size_t idx = len >> 1;
    if (idx >= kStaticQstrCount) throw std::runtime_error("mpy: static qstr out of range");
    return kStaticQstrs[idx];
  }
  len >>= 1;
  std::string s = r.str(len);
  r.byte();   // the null terminator
  return s;
}

// load_obj
Obj load_obj(Reader &r) {
  Obj o;
  uint8_t t = r.byte();
  switch (t) {
    case OBJ_FUN_TABLE: throw std::runtime_error("mpy: native function table is not supported");
    case OBJ_NONE: o.kind = Obj::Kind::None; return o;
    case OBJ_FALSE: o.kind = Obj::Kind::False; return o;
    case OBJ_TRUE: o.kind = Obj::Kind::True; return o;
    case OBJ_ELLIPSIS: o.kind = Obj::Kind::Ellipsis; return o;
    default: break;
  }
  size_t len = r.uint();
  if (len == 0 && t == OBJ_BYTES) {
    r.byte();
    o.kind = Obj::Kind::Bytes;
    return o;
  }
  if (t == OBJ_TUPLE) {
    o.kind = Obj::Kind::Tuple;
    for (size_t i = 0; i < len; ++i) o.items.push_back(load_obj(r));
    return o;
  }
  o.text = r.str(len);
  switch (t) {
    case OBJ_STR:
      r.byte();
      o.kind = Obj::Kind::Str;
      break;
    case OBJ_BYTES:
      r.byte();
      o.kind = Obj::Kind::Bytes;
      break;
    case OBJ_INT: o.kind = Obj::Kind::Int; break;
    case OBJ_FLOAT: o.kind = Obj::Kind::Float; break;
    case OBJ_COMPLEX: o.kind = Obj::Kind::Complex; break;
    default: throw std::runtime_error("mpy: unknown object type");
  }
  return o;
}

// load_raw_code: the kind (bytecode only), the children flag, and the data length, all in one uint.
RawCode load_raw(Reader &r) {
  size_t kind_len = r.uint();
  unsigned kind = kind_len & 3;
  bool has_children = (kind_len & 4) != 0;
  size_t data_len = kind_len >> 3;
  if (kind != 0) throw std::runtime_error("mpy: native code is not supported (only bytecode)");
  RawCode rc;
  rc.data = r.vec(data_len);
  if (has_children) {
    size_t n = r.uint();
    for (size_t i = 0; i < n; ++i) rc.children.push_back(load_raw(r));
  }
  return rc;
}

}  // namespace

Module load(const uint8_t *data, size_t size) {
  Reader r(data, size);
  if (size < 4) throw std::runtime_error("mpy: file too short");
  uint8_t magic = r.byte();
  uint8_t version = r.byte();
  uint8_t flags = r.byte();
  uint8_t small_int_bits = r.byte();
  if (magic != 'M' || version != kMpyVersion) throw std::runtime_error("mpy: incompatible file");
  if (((flags >> 2) & 0x2f) != 0) throw std::runtime_error("mpy: native code is not supported (arch in header)");
  if (small_int_bits > 63) throw std::runtime_error("mpy: incompatible small int size");

  Module m;
  m.version = version;
  m.flags = flags;
  m.small_int_bits = small_int_bits;
  size_t n_qstr = r.uint();
  size_t n_obj = r.uint();
  for (size_t i = 0; i < n_qstr; ++i) m.qstrs.push_back(load_qstr(r));
  for (size_t i = 0; i < n_obj; ++i) m.objs.push_back(load_obj(r));
  m.top = load_raw(r);
  if (r.pos() != r.size()) throw std::runtime_error("mpy: trailing bytes after the top-level code");
  return m;
}

Prelude read_prelude(const std::vector<uint8_t> &data) {
  Prelude p;
  size_t ip = 0;
  auto next = [&]() -> uint8_t {
    if (ip >= data.size()) throw std::runtime_error("mpy: truncated prelude");
    return data[ip++];
  };
  // MP_BC_PRELUDE_SIG_DECODE_INTO: xSSSSEAA, then more bytes while bit 7 is set (xFSSKAED)
  uint8_t z = next();
  size_t S = (z >> 3) & 0xf, E = (z >> 2) & 0x1, F = 0, A = z & 0x3, K = 0, D = 0;
  for (unsigned n = 0; z & 0x80; ++n) {
    z = next();
    S |= (size_t)(z & 0x30) << (2 * n);
    E |= (size_t)(z & 0x02) << n;
    F |= (size_t)((z & 0x40) >> 6) << n;
    A |= (size_t)(z & 0x4) << n;
    K |= (size_t)((z & 0x08) >> 3) << n;
    D |= (size_t)(z & 0x1) << n;
  }
  S += 1;
  p.n_state = (unsigned)S;
  p.n_exc_stack = (unsigned)E;
  p.scope_flags = (unsigned)F;
  p.n_pos_args = (unsigned)A;
  p.n_kwonly_args = (unsigned)K;
  p.n_def_pos_args = (unsigned)D;
  // MP_BC_PRELUDE_SIZE_DECODE_INTO: xIIIIIIC while bit 7 is set. I is the code info size, C the number of cells.
  size_t C = 0, I = 0;
  for (unsigned n = 0;; ++n) {
    z = next();
    C |= (size_t)(z & 1) << n;
    I |= (size_t)((z & 0x7e) >> 1) << (6 * n);
    if (!(z & 0x80)) break;
  }
  p.n_info = I;
  p.n_cell = C;
  p.info_offset = ip;
  p.cells_offset = ip + I;
  p.code_offset = p.cells_offset + C;
  if (p.code_offset > data.size()) throw std::runtime_error("mpy: prelude larger than the function");
  return p;
}

std::vector<Insn> decode_code(const uint8_t *code, size_t n) {
  // MP_BC_FORMAT(op): 0 byte, 1 qstr, 2 variable uint, 3 offset (bc0.h's magic number)
  auto format_of = [](uint8_t op) -> uint8_t { return (0x000003a4u >> (2 * (op >> 4))) & 3; };
  // MP_BC_OPCODE_HAS_SIGNED_OFFSET: UNWIND_JUMP (0x40) .. POP_JUMP_IF_FALSE (0x44)
  auto signed_offset = [](uint8_t op) { return op >= 0x40 && op <= 0x44; };
  std::vector<Insn> out;
  size_t ip = 0;
  auto at = [&](size_t k) -> uint8_t {
    if (k >= n) throw std::runtime_error("mpy: instruction runs past the end of the bytecode");
    return code[k];
  };
  while (ip < n) {
    Insn in;
    in.offset = ip;
    size_t p = ip;
    in.opcode = at(p++);
    in.format = format_of(in.opcode);
    int64_t arg = 0;
    if (in.format == 1 || in.format == 2) {   // QSTR and VAR_UINT
      arg = at(p) & 0x7f;
      if (in.opcode == 0x22 && (arg & 0x40) != 0) arg |= ~(int64_t)0x7f;   // LOAD_CONST_SMALL_INT is signed
      while (at(p) & 0x80) arg = (arg << 7) | (at(++p) & 0x7f);
      ++p;
    } else if (in.format == 3) {   // OFFSET
      if ((at(p) & 0x80) == 0) {
        arg = at(p++);
        if (signed_offset(in.opcode)) arg -= 0x40;
      } else {
        arg = (at(p) & 0x7f) | (at(p + 1) << 7);
        p += 2;
        if (signed_offset(in.opcode)) arg -= 0x4000;
      }
    }
    if ((in.opcode & 0x9e) == 0) in.extra = at(p++);   // MP_BC_MASK_EXTRA_BYTE: this opcode has an extra byte
    in.arg = arg;
    in.size = (uint8_t)(p - ip);
    ip = p;
    out.push_back(in);
  }
  if (ip != n) throw std::runtime_error("mpy: bytecode does not end on an instruction");
  return out;
}

}  // namespace mpy
