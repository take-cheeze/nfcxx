// The SPIR-V module builder (scripts/pathb-spirv-emit.rb: class Spv).
#include "spv.hpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstring>

#include "ir.hpp"

const int PUSH_SIZES[P_COUNT] = {8, 8, 8, 8, 8, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 8, 8, 8};

static std::vector<uint32_t> push_offsets() {
  std::vector<uint32_t> o(P_COUNT);
  for (int i = 0; i < P_COUNT; i++) {
    uint32_t off = i == 0 ? 0 : o[i - 1] + PUSH_SIZES[i - 1];
    uint32_t size = PUSH_SIZES[i];
    o[i] = (off + size - 1) / size * size;
  }
  return o;
}
static const std::vector<uint32_t> PUSH_OFFSETS = push_offsets();

namespace {
// memo tags (the Ruby's symbols)
enum Tag : int64_t {
  M_VOID = 1, M_BOOL, M_INT, M_FLOAT, M_VEC3, M_VEC3_64, M_PTR, M_FN, M_STRUCT, M_CINT, M_CFLOAT, M_CFBITS, M_CBOOL, M_SPEC,
  M_WGSIZE, M_BUILTIN, M_PUSH, M_PRIVATE, M_ARRAY, M_WGSVAR, M_BUILTIN_U32
};

// GLSL.std.450 -> OpenCL.std (the Ruby's OPENCL_OF_GLSL) and the OpenCL.std-only codes (OPENCL_ONLY)
int opencl_of_glsl(int g) {
  static const int t[][2] = {{1, 55}, {3, 66}, {4, 23}, {8, 25}, {9, 12}, {13, 57}, {14, 14}, {15, 62}, {16, 3}, {17, 0},
                             {18, 6}, {19, 59}, {20, 15}, {21, 63}, {25, 7}, {26, 48}, {27, 19}, {28, 37}, {29, 20},
                             {30, 38}, {31, 61}, {32, 56}, {37, 28}, {40, 27}, {43, 95}, {46, 99}, {50, 26}};
  for (auto &p : t)
    if (p[0] == g) return p[1];
  throw std::runtime_error("key not found: " + std::to_string(g));
}
}  // namespace

// a double as Ruby packs it into a float ([v].pack("e"), pack.c VALUE_to_float): beyond FLT_MAX it is an infinity
float ruby_float(double d) {
  if (std::isnan(d)) return NAN;
  if (d < -FLT_MAX) return -INFINITY;
  if (d <= FLT_MAX) return (float)d;
  return INFINITY;
}

uint32_t *Spv::find(const std::vector<int64_t> &k) {
  auto it = memo_.find(k);
  return it == memo_.end() ? nullptr : &it->second;
}

void Spv::cap(uint32_t c) {
  if (std::find(caps_.begin(), caps_.end(), c) == caps_.end()) caps_.push_back(c);
}

void Spv::ext(const std::string &name) {
  if (std::find(exts_.begin(), exts_.end(), name) == exts_.end()) exts_.push_back(name);
}

uint32_t Spv::glsl_id() {
  if (!glsl_) glsl_ = id();
  return glsl_;
}

uint32_t Spv::ext_num(int g) {
  if (g >= 1000) {
    if (!kernel_cl) throw Refused("an OpenCL.std instruction (no GLSL.std.450 counterpart) outside a Kernel module");
    switch (g) {
      case 1000: return 22;
      case 1001: return 40;
      case 1002: return 18;
    }
    throw std::runtime_error("key not found: " + std::to_string(g));
  }
  return kernel_cl ? opencl_of_glsl(g) : g;
}

uint32_t Spv::t_void() {
  if (auto *p = find({M_VOID})) return *p;
  uint32_t i = id();
  decl({19, i});
  return put({M_VOID}, i);
}

uint32_t Spv::t_bool() {
  if (auto *p = find({M_BOOL})) return *p;
  uint32_t i = id();
  decl({20, i});
  return put({M_BOOL}, i);
}

uint32_t Spv::t_int(int bits) {
  if (auto *p = find({M_INT, bits})) return *p;
  uint32_t i = id();
  decl({21, i, (uint32_t)bits, 0});
  return put({M_INT, bits}, i);
}

uint32_t Spv::t_float(int bits) {
  if (bits == 64) cap(10);
  if (auto *p = find({M_FLOAT, bits})) return *p;
  uint32_t i = id();
  decl({22, i, (uint32_t)bits});
  return put({M_FLOAT, bits}, i);
}

uint32_t Spv::t_vec3() {
  if (auto *p = find({M_VEC3})) return *p;
  uint32_t i = id();
  uint32_t e = t_int(32);
  decl({23, i, e, 3});
  return put({M_VEC3}, i);
}

uint32_t Spv::builtin_vec_t() {
  if (!kernel_cl) return t_vec3();
  if (auto *p = find({M_VEC3_64})) return *p;
  uint32_t i = id();
  uint32_t e = t_int(64);
  decl({23, i, e, 3});
  return put({M_VEC3_64}, i);
}

uint32_t Spv::t_ptr(uint32_t sc, uint32_t elem) {
  if (auto *p = find({M_PTR, sc, elem})) return *p;
  uint32_t i = id();
  decl({32, i, sc, elem});
  return put({M_PTR, sc, elem}, i);
}

uint32_t Spv::t_fn(uint32_t ret, const std::vector<uint32_t> &params) {
  std::vector<int64_t> k{M_FN, ret};
  for (uint32_t p : params) k.push_back(p);
  if (auto *p = find(k)) return *p;
  uint32_t i = id();
  Inst d{33, i, ret};
  d.insert(d.end(), params.begin(), params.end());
  decl(std::move(d));
  return put(k, i);
}

uint32_t Spv::t_push_struct() {
  // the members are evaluated before the memo (the Ruby's arguments of t_struct)
  std::vector<uint32_t> members;
  for (int m = 0; m < P_COUNT; m++) members.push_back(PUSH_SIZES[m] == 8 ? t_int(64) : t_int(32));
  if (auto *p = find({M_STRUCT})) return *p;
  uint32_t i = id();
  Inst d{30, i};
  d.insert(d.end(), members.begin(), members.end());
  decl(std::move(d));
  if (!kernel_cl) {
    ann({OP_NAME_DECORATE, i, DEC_BLOCK});
    for (int k = 0; k < P_COUNT; k++) ann({OP_MEMBER_DECORATE, i, (uint32_t)k, DEC_OFFSET, PUSH_OFFSETS[k]});
  }
  return put({M_STRUCT}, i);
}

uint32_t Spv::c_int(int bits, int64_t v) {
  uint32_t t = t_int(bits);
  uint64_t u = bits == 64 ? (uint64_t)v : ((uint64_t)v & ((1ull << bits) - 1));
  std::vector<int64_t> k{M_CINT, bits, (int64_t)u};
  if (auto *p = find(k)) return *p;
  uint32_t i = id();
  if (bits == 64) decl({43, t, i, (uint32_t)(u & 0xffffffffu), (uint32_t)(u >> 32)});
  else decl({43, t, i, (uint32_t)u});
  return put(k, i);
}

uint32_t Spv::c_float(int bits, double v) {
  uint32_t t = t_float(bits);
  // the Ruby's memo key is the Float: 0.0 and -0.0 are the same key (the first one seen makes the constant)
  double kv = v == 0.0 ? 0.0 : v;
  int64_t kb;
  std::memcpy(&kb, &kv, 8);
  std::vector<int64_t> k{M_CFLOAT, bits, kb};
  if (auto *p = find(k)) return *p;
  uint32_t i = id();
  if (bits == 32) {
    float f = ruby_float(v);
    uint32_t w;
    std::memcpy(&w, &f, 4);
    decl({43, t, i, w});
  } else {
    uint64_t w;
    std::memcpy(&w, &v, 8);
    decl({43, t, i, (uint32_t)(w & 0xffffffffu), (uint32_t)(w >> 32)});
  }
  return put(k, i);
}

uint32_t Spv::c_float_bits(int bits, uint64_t pattern) {
  uint32_t t = t_float(bits);
  std::vector<int64_t> k{M_CFBITS, bits, (int64_t)pattern};
  if (auto *p = find(k)) return *p;
  uint32_t i = id();
  if (bits == 32) decl({43, t, i, (uint32_t)(pattern & 0xffffffffu)});
  else decl({43, t, i, (uint32_t)(pattern & 0xffffffffu), (uint32_t)((pattern >> 32) & 0xffffffffu)});
  return put(k, i);
}

uint32_t Spv::c_bool(bool v) {
  uint32_t t = t_bool();
  if (auto *p = find({M_CBOOL, v})) return *p;
  uint32_t i = id();
  decl({v ? 41u : 42u, t, i});
  return put({M_CBOOL, v}, i);
}

uint32_t Spv::spec_u32(uint32_t spec_id, uint32_t dflt) {
  if (auto *p = find({M_SPEC, spec_id})) return *p;
  uint32_t i = id();
  uint32_t t = t_int(32);
  decl({50, t, i, dflt});
  ann({71, i, DEC_SPEC_ID, spec_id});
  return put({M_SPEC, spec_id}, i);
}

uint32_t Spv::workgroup_size(const std::vector<uint32_t> &ids) {
  std::vector<int64_t> k{M_WGSIZE};
  for (uint32_t x : ids) k.push_back(x);
  if (auto *p = find(k)) return *p;
  uint32_t i = id();
  uint32_t t = t_vec3();
  Inst d{51, t, i};
  d.insert(d.end(), ids.begin(), ids.end());
  decl(std::move(d));
  ann({71, i, 11, 25});
  return put(k, i);
}

uint32_t Spv::var(uint32_t sc, uint32_t ptr_type) {
  uint32_t i = id();
  decl({59, ptr_type, i, sc});
  return i;
}

uint32_t Spv::builtin_input(uint32_t builtin) {
  if (auto *p = find({M_BUILTIN, builtin})) return *p;
  uint32_t vt = builtin_vec_t();
  uint32_t pt = t_ptr(SC_INPUT, vt);
  uint32_t v = var(SC_INPUT, pt);
  ann({71, v, DEC_BUILTIN, builtin});
  return put({M_BUILTIN, builtin}, v);
}

uint32_t Spv::builtin_input_u32(uint32_t builtin) {
  if (auto *p = find({M_BUILTIN_U32, builtin})) return *p;
  uint32_t e = t_int(32);
  uint32_t pt = t_ptr(SC_INPUT, e);
  uint32_t v = var(SC_INPUT, pt);
  ann({71, v, DEC_BUILTIN, builtin});
  return put({M_BUILTIN_U32, builtin}, v);
}

uint32_t Spv::push_var() {
  if (auto *p = find({M_PUSH})) return *p;
  t_int(64);
  t_int(32);
  uint32_t st = t_push_struct();
  uint32_t pt = t_ptr(SC_PUSH_CONSTANT, st);
  uint32_t v = var(SC_PUSH_CONSTANT, pt);
  return put({M_PUSH}, v);
}

uint32_t Spv::private_var(uint32_t elem) {
  if (auto *p = find({M_PRIVATE, elem})) return *p;
  uint32_t pt = t_ptr(SC_PRIVATE, elem);
  uint32_t v = var(SC_PRIVATE, pt);
  return put({M_PRIVATE, elem}, v);
}

uint32_t Spv::t_array(uint32_t elem, uint32_t len) {
  if (auto *p = find({M_ARRAY, elem, len})) return *p;
  uint32_t i = id();
  uint32_t n = c_u32(len);
  decl({28, i, elem, n});
  return put({M_ARRAY, elem, len}, i);
}

uint32_t Spv::wgs_var(uint32_t words) {
  if (auto *p = find({M_WGSVAR, words})) return *p;
  uint32_t e = t_int(32);
  uint32_t a = t_array(e, words);
  uint32_t pt = t_ptr(SC_WORKGROUP, a);
  uint32_t v = var(SC_WORKGROUP, pt);
  return put({M_WGSVAR, words}, v);
}

std::vector<uint32_t> str_words(const std::string &s) {
  std::vector<uint8_t> b(s.begin(), s.end());
  b.push_back(0);
  while (b.size() % 4) b.push_back(0);
  std::vector<uint32_t> w;
  for (size_t k = 0; k < b.size(); k += 4) w.push_back(b[k] | (b[k + 1] << 8) | (b[k + 2] << 16) | ((uint32_t)b[k + 3] << 24));
  return w;
}

std::vector<uint32_t> Spv::finish(uint32_t version) {
  std::vector<uint32_t> out{0x07230203, version, 0, 0, 0};
  std::vector<Inst> body;
  for (uint32_t c : caps_) body.push_back({17, c});
  for (auto &e : exts_) {
    Inst i{10};
    auto w = str_words(e);
    i.insert(i.end(), w.begin(), w.end());
    body.push_back(i);
  }
  {
    Inst i{11, glsl_id()};
    auto w = str_words(kernel_cl ? "OpenCL.std" : "GLSL.std.450");
    i.insert(i.end(), w.begin(), w.end());
    body.push_back(i);
  }
  body.push_back(kernel_cl ? Inst{14, 2, 2} : Inst{14, 5348, 3});
  for (auto &e : entries_) {
    Inst i{15, e.model, e.fid};
    auto w = str_words(e.name);
    i.insert(i.end(), w.begin(), w.end());
    i.insert(i.end(), e.iface.begin(), e.iface.end());
    body.push_back(i);
  }
  for (auto &m : modes_) body.push_back(m);
  out[3] = bound_;
  auto emit = [&](const std::vector<Inst> &list) {
    for (auto &inst : list) {
      out.push_back(((uint32_t)inst.size() << 16) | inst[0]);
      out.insert(out.end(), inst.begin() + 1, inst.end());
    }
  };
  emit(body);
  emit(anns_);
  emit(types_);
  emit(funcs_);
  return out;
}
