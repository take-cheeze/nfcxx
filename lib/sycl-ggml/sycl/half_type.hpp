// Minimal sycl::half and sycl::half2 for the ggml-sycl sources (fill, common.hpp, dpct/helper.hpp). The storage is the
// IEEE binary16 bit pattern; arithmetic goes through float. Round-to-nearest-even on conversion from float.
#ifndef NFCXX_SYCL_GGML_HALF_TYPE_HPP
#define NFCXX_SYCL_GGML_HALF_TYPE_HPP

#include <cmath>
#include <cstdint>
#include <cstring>
#include <type_traits>
// The real sycl headers include these; the ggml sources rely on them (std::lock_guard in dpct/helper.hpp).
#include <memory>
#include <mutex>
#include <complex>
#include <cstddef>
#include <ostream>

namespace sycl {

class half {
 public:
  // The default constructor is trivial (no member initialiser): an array of half (vec<half, N>'s storage) is then
  // default-initialised without a constructor call, and the front end emits no constructor address for the device pass
  // (pathb-spirv-emit refuses "address of function" for a __cxa_vec_ctor over a non-trivial element type). value-init
  // (half()) still zeroes the bits.
  half() = default;
  half(float f) : bits_(from_float(f)) {}
  operator float() const { return to_float(bits_); }
  uint16_t bits() const { return bits_; }
  static half from_bits(uint16_t b) { half h; h.bits_ = b; return h; }

 private:
  uint16_t bits_;

  static float to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1f;
    uint32_t man = h & 0x3ff;
    uint32_t out;
    if (exp == 0) {
      if (man == 0) {
        out = sign;
      } else {  // subnormal: normalise
        int e = -1;
        do { man <<= 1; e++; } while ((man & 0x400) == 0);
        man &= 0x3ff;
        out = sign | (uint32_t)(127 - 15 - e) << 23 | man << 13;
      }
    } else if (exp == 31) {
      out = sign | 0x7f800000u | man << 13;
    } else {
      out = sign | (exp + 112) << 23 | man << 13;
    }
    float f;
    std::memcpy(&f, &out, 4);
    return f;
  }

  static uint16_t from_float(float f) {
    uint32_t x;
    std::memcpy(&x, &f, 4);
    uint16_t sign = (uint16_t)((x >> 16) & 0x8000);
    uint32_t exp = (x >> 23) & 0xff;
    uint32_t man = x & 0x7fffff;
    if (exp == 0xff) return sign | 0x7c00 | (man ? 0x200 : 0);
    int32_t e = (int32_t)exp - 127 + 15;
    if (e >= 31) return sign | 0x7c00;
    if (e <= 0) {
      if (e < -10) return sign;
      man |= 0x800000;
      uint32_t shift = (uint32_t)(14 - e);
      uint32_t half_m = man >> shift;
      uint32_t rem = man & ((1u << shift) - 1), mid = 1u << (shift - 1);
      if (rem > mid || (rem == mid && (half_m & 1))) half_m++;
      return sign | (uint16_t)half_m;
    }
    uint32_t hm = man >> 13, rem = man & 0x1fff;
    uint32_t out = (uint32_t)e << 10 | hm;
    if (rem > 0x1000 || (rem == 0x1000 && (out & 1))) out++;
    return sign | (uint16_t)out;
  }
};

// usm_allocator: the USM allocator template the dpct helper names (its members are not used by the ops under test).
template <class T, usm::alloc AllocKind> class usm_allocator {
 public:
  using value_type = T;
  usm_allocator() = default;
  template <class U> usm_allocator(const usm_allocator<U, AllocKind> &) {}
  T *allocate(size_t n) { return static_cast<T *>(::operator new(n * sizeof(T))); }
  void deallocate(T *p, size_t) { ::operator delete(p); }
};

// backend names in a stream (dpct::get_sycl_backend_name and friends).
inline std::ostream &operator<<(std::ostream &o, backend b) { return o << (int)b; }

// pown: x raised to an integer power (the ops use it through dpct's pow overloads).
inline float pown(float x, int n) {
  float r = 1.0f;
  for (int i = 0; i < (n < 0 ? -n : n); i++) r *= x;
  return n < 0 ? 1.0f / r : r;
}
inline double pown(double x, int n) {
  double r = 1.0;
  for (int i = 0; i < (n < 0 ? -n : n); i++) r *= x;
  return n < 0 ? 1.0 / r : r;
}

class half2 {
 public:
  half2() = default;
  half2(half a, half b) : v_{a, b} {}
  half &x() { return v_[0]; }
  half &y() { return v_[1]; }
  const half &x() const { return v_[0]; }
  const half &y() const { return v_[1]; }
  half &operator[](int i) { return v_[i]; }
  const half &operator[](int i) const { return v_[i]; }

 private:
  half v_[2];
};

// Free functions the ggml sources call on device values (the real headers provide them; these are the host-side forms).
template <class To, class From> To bit_cast(const From &f) {
  static_assert(sizeof(To) == sizeof(From), "bit_cast size");
  To t;
  std::memcpy(&t, &f, sizeof(To));
  return t;
}
inline bool isnan(float f) { return f != f; }
inline bool isnan(half h) { return (float)h != (float)h; }
template <class T> T mul_hi(T a, T b) { return (T)(((uint64_t)a * (uint64_t)b) >> 32); }
inline half fmax(half a, half b) { return half((float)a > (float)b ? (float)a : (float)b); }

// Math on half, computed in float and rounded back (the compat math templates in lib/sycl take arithmetic types only).
// The ggml-sycl ops instantiate their F16 arm even for F32 tensors, so these must exist for the names they call.
#define NFCXX_SYCL_HALF_MATH1(name, cf) inline half name(half x) { return half(cf(static_cast<float>(x))); }
NFCXX_SYCL_HALF_MATH1(sqrt, std::sqrt)
NFCXX_SYCL_HALF_MATH1(exp, std::exp)
NFCXX_SYCL_HALF_MATH1(exp2, std::exp2)
NFCXX_SYCL_HALF_MATH1(log, std::log)
NFCXX_SYCL_HALF_MATH1(log2, std::log2)
NFCXX_SYCL_HALF_MATH1(sin, std::sin)
NFCXX_SYCL_HALF_MATH1(cos, std::cos)
NFCXX_SYCL_HALF_MATH1(tan, std::tan)
NFCXX_SYCL_HALF_MATH1(tanh, std::tanh)
NFCXX_SYCL_HALF_MATH1(fabs, std::fabs)
NFCXX_SYCL_HALF_MATH1(floor, std::floor)
NFCXX_SYCL_HALF_MATH1(ceil, std::ceil)
NFCXX_SYCL_HALF_MATH1(trunc, std::trunc)
NFCXX_SYCL_HALF_MATH1(round, std::round)
#undef NFCXX_SYCL_HALF_MATH1
// erf, expm1, log1p: templates on half, so that only a call that is reached is emitted (see sycl.hpp: no device lowering).
template <class H, class = typename std::enable_if<std::is_same<H, half>::value>::type> inline H erf(H x) { return H(sycl::erf((float)x)); }
template <class H, class = typename std::enable_if<std::is_same<H, half>::value>::type> inline H expm1(H x) { return H(sycl::expm1((float)x)); }
template <class H, class = typename std::enable_if<std::is_same<H, half>::value>::type> inline H log1p(H x) { return H(sycl::log1p((float)x)); }
inline half fmin(half a, half b) { return half((float)a < (float)b ? (float)a : (float)b); }

namespace ext {
namespace oneapi {
namespace experimental {
enum class architecture { unknown };
}  // namespace experimental
}  // namespace oneapi
}  // namespace ext

}  // namespace sycl

#endif
