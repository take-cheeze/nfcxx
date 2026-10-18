// A SYCL 2020 subset for nfcxx. Single-source C++: `q.submit([&](handler &h) { ... h.parallel_for(r, [=](id<1> i) {...}); })`.
// Two execution paths share this header:
//
//   host (default)   the kernel is an ordinary C++ loop on the CPU. Any C++17 compiler builds and runs the program.
//   WebGPU           -DNFCXX_SYCL_WEBGPU. scripts/sycl-build.sh compiles the same source a second time with
//                    -D__NFCXX_SYCL_DEVICE__ (the "device pass"), lowers each kernel's closure `operator()` and
//                    everything it calls to WGSL (scripts/pathb-wgsl-emit.rb), and lib/sycl/rt_pipe.hpp runs the WGSL
//                    through WebGPU. The host copies the closure object's bytes to the GPU as the kernel's arguments, so
//                    a kernel may capture scalars, accessors and local_accessors by value.
//
// Layout rule: every class below has the same fields in both passes (only function bodies differ), so the device reads
// the closure at the offsets the device pass's layout gives it.
//
// Kernel names: a kernel is found again through the mangled name of its closure type (typeid(F).name() on the host,
// the closure's struct name in the device pass), so unnamed lambdas work. The name argument of `parallel_for<class K>`
// is accepted and ignored.
//
// Device memory model: an accessor holds the address of its buffer's device copy (a 32-bit address into one big GPU storage
// buffer), and USM pointers are host addresses whose low 32 bits are device addresses (lib/sycl/include/sycl/rt_pipe.hpp), so
// raw pointers captured by a kernel work. 64-bit integers above 2^32 and double do not exist on the device; reference
// captures are not supported by SYCL either. See docs/notes/sycl-webgpu.md.
#ifndef NFCXX_SYCL_HPP
#define NFCXX_SYCL_HPP

// A device backend is in use: NFCXX_SYCL_GPU (WebGPU: -DNFCXX_SYCL_WEBGPU, rt_pipe.hpp; Vulkan: -DNFCXX_SYCL_VULKAN,
// rt_vulkan.hpp; OpenCL: -DNFCXX_SYCL_OPENCL, rt_opencl.hpp; Level Zero: -DNFCXX_SYCL_LEVEL_ZERO, rt_level_zero.hpp).
// The SPIR-V or WGSL image comes from scripts/sycl-build.sh.
#if defined(NFCXX_SYCL_WEBGPU) || defined(NFCXX_SYCL_VULKAN) || defined(NFCXX_SYCL_OPENCL) || defined(NFCXX_SYCL_LEVEL_ZERO)
#define NFCXX_SYCL_GPU 1
#endif

#ifdef __NFCXX_SYCL_DEVICE__
// ---- device intrinsics: the WGSL emitter lowers these calls (scripts/pathb-wgsl-emit.rb)
extern "C" {
unsigned __nfcxx_sycl_gid_x(void);
unsigned __nfcxx_sycl_gid_y(void);
unsigned __nfcxx_sycl_gid_z(void);
unsigned __nfcxx_sycl_lid_x(void);
unsigned __nfcxx_sycl_lid_y(void);
unsigned __nfcxx_sycl_lid_z(void);
unsigned __nfcxx_sycl_group_x(void);
unsigned __nfcxx_sycl_group_y(void);
unsigned __nfcxx_sycl_group_z(void);
unsigned __nfcxx_sycl_grange_x(void);  // the global range the host asked for (the dispatch is rounded up to whole groups)
unsigned __nfcxx_sycl_grange_y(void);
unsigned __nfcxx_sycl_grange_z(void);
unsigned __nfcxx_sycl_lrange_x(void);
unsigned __nfcxx_sycl_lrange_y(void);
unsigned __nfcxx_sycl_lrange_z(void);
void *__nfcxx_sycl_closure(void);     // the closure object, copied by the host
void *__nfcxx_sycl_local_base(void);  // the work-group memory (local_accessor storage)
void *__nfcxx_sycl_scratch(void);     // 256 words of work-group memory kept for the group algorithms
void __nfcxx_sycl_barrier(void);
// sub-group shuffles (OpGroupNonUniformShuffle, ShuffleXor in the OpenCL module): the word of lane src, of lane (lane ^ mask)
unsigned __nfcxx_sycl_sg_shuffle_u32(unsigned w, unsigned src);
unsigned __nfcxx_sycl_sg_shuffle_xor_u32(unsigned w, unsigned mask);
float __nfcxx_sycl_fn1(int op, float x);  // math builtins; op is a literal: see SYCL_MATH in scripts/pathb-wgsl-emit.rb
float __nfcxx_sycl_fn2(int op, float x, float y);
float __nfcxx_sycl_fn3(int op, float x, float y, float z);
double __nfcxx_sycl_fn1_f64(int op, double x);  // the double form of __nfcxx_sycl_fn1 (erf, expm1, log1p: OpenCL.std on Float64)
// 32-bit integer atomics on global or work-group memory; they return the old value
int __nfcxx_sycl_atomic_add(void *p, int v);
int __nfcxx_sycl_atomic_max(void *p, int v);
int __nfcxx_sycl_atomic_min(void *p, int v);
int __nfcxx_sycl_atomic_umax(void *p, int v);
int __nfcxx_sycl_atomic_umin(void *p, int v);
int __nfcxx_sycl_atomic_and(void *p, int v);
int __nfcxx_sycl_atomic_or(void *p, int v);
int __nfcxx_sycl_atomic_xor(void *p, int v);
int __nfcxx_sycl_atomic_xchg(void *p, int v);
int __nfcxx_sycl_atomic_load(void *p);
int __nfcxx_sycl_atomic_cas(void *p, int expected, int desired);   // returns the old value
float __nfcxx_sycl_atomic_fadd(void *p, float v);
float __nfcxx_sycl_atomic_fmin(void *p, float v);
float __nfcxx_sycl_atomic_fmax(void *p, float v);
}
#endif
// The standard headers a user may rely on sycl.hpp for (DPC++ and AdaptiveCpp include them too).
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <functional>
#include <initializer_list>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <typeinfo>
#include <vector>
#include <system_error>
#include <ucontext.h>
#include <type_traits>
#include <math.h>

// clang's __builtin_assume(cond) is an optimizer hint ggml-sycl's flash-attention kernels use (fattn-vec.hpp, fattn-common.hpp).
// The front end here has no such builtin; dropping the hint changes no value.
#ifndef __builtin_assume
#define __builtin_assume(cond) ((void) 0)
#endif

#define SYCL_LANGUAGE_VERSION 202011
#define CL_SYCL_LANGUAGE_VERSION 202011
#define SYCL_EXTERNAL

typedef signed char cl_char;
typedef unsigned char cl_uchar;
typedef short cl_short;
typedef unsigned short cl_ushort;
typedef int cl_int;
typedef unsigned int cl_uint;
typedef long cl_long;
typedef unsigned long cl_ulong;
typedef float cl_float;
typedef double cl_double;

namespace sycl {
enum class rounding_mode { automatic, rte, rtz, rtp, rtn };

enum class backend { host, opencl, level_zero, cuda, hip, vulkan, webgpu, ext_oneapi_level_zero };

using size_t = unsigned long;

namespace detail {
template <bool B, class T = void> struct enable_if {};
template <class T> struct enable_if<true, T> { using type = T; };
template <bool B, class T = void> using enable_if_t = typename enable_if<B, T>::type;
// id<1> and item<1> convert to size_t (SYCL 2020). A mixin, not a conversion function template: the EDG front end does not
// find a template conversion function when it looks for a built-in operator's operand (`id == 5`).
template <class Derived, int D> struct size_conv {};
template <class Derived> struct size_conv<Derived, 1> {
  operator unsigned long() const { return static_cast<const Derived &>(*this)[0]; }
};
template <class T> struct remove_cv_ref { using type = T; };
template <class T> struct remove_cv_ref<const T> { using type = T; };
template <class T> struct remove_cv_ref<T &> { using type = T; };
template <class T> struct remove_cv_ref<const T &> { using type = T; };
template <class T> struct remove_cv_ref<T &&> { using type = T; };
}  // namespace detail

// ------------------------------------------------------------------------------------------------ range, id, item

template <int D = 1> class range {
 public:
  range() { for (int i = 0; i < D; i++) v_[i] = 0; }
  range(size_t a) { v_[0] = a; for (int i = 1; i < D; i++) v_[i] = 0; }
  range(size_t a, size_t b) { static_assert(D == 2, "range<2>"); v_[0] = a; v_[1] = b; }
  range(size_t a, size_t b, size_t c) { static_assert(D == 3, "range<3>"); v_[0] = a; v_[1] = b; v_[2] = c; }
  size_t get(int i) const { return v_[i]; }
  size_t &operator[](int i) { return v_[i]; }
  const size_t &operator[](int i) const { return v_[i]; }
  size_t size() const { size_t n = 1; for (int i = 0; i < D; i++) n *= v_[i]; return n; }
  friend range operator*(const range &a, size_t k) { range r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] * k; return r; }
  friend range operator/(const range &a, size_t k) { range r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] / k; return r; }
  friend range operator+(const range &a, size_t k) { range r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] + k; return r; }

 private:
  size_t v_[D];
};

template <int D = 1> class id : public detail::size_conv<id<D>, D> {
 public:
  id() { for (int i = 0; i < D; i++) v_[i] = 0; }
  id(size_t a) { v_[0] = a; for (int i = 1; i < D; i++) v_[i] = 0; }
  id(size_t a, size_t b) { static_assert(D == 2, "id<2>"); v_[0] = a; v_[1] = b; }
  id(size_t a, size_t b, size_t c) { static_assert(D == 3, "id<3>"); v_[0] = a; v_[1] = b; v_[2] = c; }
  id(const range<D> &r) { for (int i = 0; i < D; i++) v_[i] = r[i]; }
  size_t get(int i) const { return v_[i]; }
  size_t &operator[](int i) { return v_[i]; }
  const size_t &operator[](int i) const { return v_[i]; }
  friend id operator+(const id &a, const id &b) { id r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] + b.v_[i]; return r; }
  friend id operator-(const id &a, const id &b) { id r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] - b.v_[i]; return r; }
  friend id operator*(const id &a, size_t k) { id r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] * k; return r; }
  friend id operator+(const id &a, size_t k) { id r; for (int i = 0; i < D; i++) r.v_[i] = a.v_[i] + k; return r; }

 private:
  size_t v_[D];
};


// Comparisons are templates so that `id == 5` is the built-in comparison through id's size_t conversion, not a conversion of 5.
template <int D> inline bool operator==(const range<D> &a, const range<D> &b) { for (int i = 0; i < D; i++) if (a[i] != b[i]) return false; return true; }
template <int D> inline bool operator!=(const range<D> &a, const range<D> &b) { return !(a == b); }
template <int D> inline bool operator==(const id<D> &a, const id<D> &b) { for (int i = 0; i < D; i++) if (a[i] != b[i]) return false; return true; }
template <int D> inline bool operator!=(const id<D> &a, const id<D> &b) { return !(a == b); }
template <int D> inline range<D> operator+(const range<D> &a, const range<D> &b) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] + b[i]; return r; }
template <int D> inline range<D> operator-(const range<D> &a, const range<D> &b) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] - b[i]; return r; }
template <int D> inline range<D> operator*(const range<D> &a, const range<D> &b) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] * b[i]; return r; }
// dpct::dim3 converts to range<3> with its x, y, z in reverse index order (dim3 operator sycl::range<3>), so a non-template
// overload accepts dim3 * range<3> and range<3> * dim3 through that conversion (a template cannot deduce from dim3).
inline range<3> operator*(const range<3> &a, const range<3> &b) { return range<3>(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }
template <int D> inline range<D> operator/(const range<D> &a, const range<D> &b) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] / b[i]; return r; }
template <int D> inline range<D> operator%(const range<D> &a, const range<D> &b) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] % b[i]; return r; }
template <int D> inline range<D> operator-(const range<D> &a, size_t k) { range<D> r; for (int i = 0; i < D; i++) r[i] = a[i] - k; return r; }
template <int D> inline range<D> operator*(size_t k, const range<D> &a) { return a * k; }
template <int D> inline id<D> operator/(const id<D> &a, const id<D> &b) { id<D> r; for (int i = 0; i < D; i++) r[i] = a[i] / b[i]; return r; }
template <int D> inline id<D> operator*(const id<D> &a, const id<D> &b) { id<D> r; for (int i = 0; i < D; i++) r[i] = a[i] * b[i]; return r; }
template <int D> inline id<D> operator-(const id<D> &a, size_t k) { id<D> r; for (int i = 0; i < D; i++) r[i] = a[i] - k; return r; }
template <int D> inline id<D> operator/(const id<D> &a, size_t k) { id<D> r; for (int i = 0; i < D; i++) r[i] = a[i] / k; return r; }
template <int D> inline id<D> operator%(const id<D> &a, size_t k) { id<D> r; for (int i = 0; i < D; i++) r[i] = a[i] % k; return r; }
template <int D> inline id<D> operator*(size_t k, const id<D> &a) { return a * k; }
template <int D> inline id<D> operator+(size_t k, const id<D> &a) { return a + k; }

template <int D = 1, bool WithOffset = true> class item : public detail::size_conv<item<D, WithOffset>, D> {
 public:
  item() {}
  item(const id<D> &i, const range<D> &r) : id_(i), r_(r) {}
  id<D> get_id() const { return id_; }
  size_t get_id(int d) const { return id_[d]; }
  size_t operator[](int d) const { return id_[d]; }
  range<D> get_range() const { return r_; }
  size_t get_range(int d) const { return r_[d]; }
  size_t get_linear_id() const {
    size_t l = 0;
    for (int i = 0; i < D; i++) l = l * r_[i] + id_[i];
    return l;
  }
  operator id<D>() const { return id_; }

 private:
  id<D> id_;
  range<D> r_;
};

template <int D = 1> class nd_range {
 public:
  nd_range() {}
  nd_range(const range<D> &g, const range<D> &l) : g_(g), l_(l) {}
  range<D> get_global_range() const { return g_; }
  range<D> get_local_range() const { return l_; }
  range<D> get_group_range() const { range<D> r; for (int i = 0; i < D; i++) r[i] = g_[i] / l_[i]; return r; }

 private:
  range<D> g_, l_;
};

enum class memory_scope { work_item, sub_group, work_group, device, system };
enum class memory_order { relaxed, acquire, release, acq_rel, seq_cst };
namespace access {
enum class fence_space { local_space, global_space, global_and_local };
enum class address_space { global_space, local_space, constant_space, private_space, generic_space };
}

namespace detail {
void barrier_on_host();
}

template <int D = 1> class group {
 public:
  group() {}
  group(const id<D> &gid, const range<D> &lr, const range<D> &gr) : gid_(gid), lr_(lr), gr_(gr) {}
  id<D> get_group_id() const { return gid_; }
  size_t get_group_id(int d) const { return gid_[d]; }
  size_t operator[](int d) const { return gid_[d]; }
  range<D> get_local_range() const { return lr_; }
  size_t get_local_range(int d) const { return lr_[d]; }
  range<D> get_group_range() const { return gr_; }
  size_t get_group_linear_id() const { size_t l = 0; for (int i = 0; i < D; i++) l = l * gr_[i] + gid_[i]; return l; }
  bool leader() const;

 private:
  id<D> gid_;
  range<D> lr_, gr_;
};

// ------------------------------------------------------------------------------------------------ pointers

namespace access {
enum class decorated { no, yes, legacy };
}
inline constexpr memory_scope memory_scope_work_item = memory_scope::work_item;
inline constexpr memory_scope memory_scope_sub_group = memory_scope::sub_group;
inline constexpr memory_scope memory_scope_work_group = memory_scope::work_group;
inline constexpr memory_scope memory_scope_device = memory_scope::device;
inline constexpr memory_scope memory_scope_system = memory_scope::system;
inline constexpr memory_order memory_order_relaxed = memory_order::relaxed;
inline constexpr memory_order memory_order_acquire = memory_order::acquire;
inline constexpr memory_order memory_order_release = memory_order::release;
inline constexpr memory_order memory_order_acq_rel = memory_order::acq_rel;
inline constexpr memory_order memory_order_seq_cst = memory_order::seq_cst;
using cl_char = signed char;
using cl_uchar = unsigned char;
using cl_short = short;
using cl_ushort = unsigned short;
using cl_int = int;
using cl_uint = unsigned;
using cl_long = long;
using cl_ulong = unsigned long;
using cl_float = float;
using cl_double = double;

// A pointer tagged with an address space. All spaces are the same C++ pointer here; the device pass tells them apart by the
// address bits (scripts/pathb-wgsl-emit.rb).
template <class T, access::address_space AS = access::address_space::generic_space, access::decorated Dec = access::decorated::legacy>
class multi_ptr {
 public:
  using value_type = T;
  multi_ptr() : p_(nullptr) {}
  multi_ptr(T *p) : p_(p) {}
  multi_ptr(std::nullptr_t) : p_(nullptr) {}
  T *get() const { return p_; }
  T *get_raw() const { return p_; }
  T *get_decorated() const { return p_; }
  T &operator*() const { return *p_; }
  T *operator->() const { return p_; }
  T &operator[](long i) const { return p_[i]; }
  operator T *() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  multi_ptr &operator++() { ++p_; return *this; }
  multi_ptr operator++(int) { multi_ptr r(*this); ++p_; return r; }
  multi_ptr &operator--() { --p_; return *this; }
  multi_ptr &operator+=(long n) { p_ += n; return *this; }
  multi_ptr &operator-=(long n) { p_ -= n; return *this; }
  friend multi_ptr operator+(const multi_ptr &a, long n) { return multi_ptr(a.p_ + n); }
  friend multi_ptr operator-(const multi_ptr &a, long n) { return multi_ptr(a.p_ - n); }

 private:
  T *p_;
};
template <class T, access::decorated Dec = access::decorated::legacy> using global_ptr = multi_ptr<T, access::address_space::global_space, Dec>;
template <class T, access::decorated Dec = access::decorated::legacy> using local_ptr = multi_ptr<T, access::address_space::local_space, Dec>;
template <class T, access::decorated Dec = access::decorated::legacy> using private_ptr = multi_ptr<T, access::address_space::private_space, Dec>;
template <class T, access::decorated Dec = access::decorated::legacy> using constant_ptr = multi_ptr<T, access::address_space::constant_space, Dec>;
template <access::address_space AS, access::decorated Dec, class T> inline multi_ptr<T, AS, Dec> address_space_cast(T *p) { return multi_ptr<T, AS, Dec>(p); }
template <class T, access::address_space AS = access::address_space::generic_space, access::decorated Dec = access::decorated::legacy>
inline multi_ptr<T, AS, Dec> make_ptr(T *p) { return multi_ptr<T, AS, Dec>(p); }

template <class T, int N> class vec;

// A sub-group has 16 lanes (detail::kSubGroupSize: the Intel default that ggml uses; the work-groups of a kernel that uses
// sub-groups are multiples of it). Lane k of sub-group j is the work-item with local linear id 16j+k. The exchanges are real:
// on the device they are the sub-group shuffles of the OpenCL module (scripts/pathb-spirv-emit.rb gives such a kernel the
// SubgroupSize 16 execution mode); on the host the work-items of a group, which run as fibers, swap the words through the
// group's scratch words, with a barrier before and after each swap.
namespace detail {
constexpr unsigned kSubGroupSize = 16;
inline unsigned sg_shuffle32(unsigned w, unsigned src);       // the word of lane src (0..15) of the caller's sub-group
inline unsigned sg_shuffle_xor32(unsigned w, unsigned mask);  // the word of lane (lane ^ mask), mask 0..15
// x of any trivially copyable type, moved word by word
template <class T> inline T sg_shuffle(T x, unsigned src) {
  constexpr size_t n = (sizeof(T) + 3) / 4;
  unsigned w[n] = {};
  std::memcpy(w, &x, sizeof(T));
  for (size_t i = 0; i < n; i++) w[i] = sg_shuffle32(w[i], src);
  T r;
  std::memcpy(&r, w, sizeof(T));
  return r;
}
template <class T> inline T sg_shuffle_xor(T x, unsigned mask) {
  constexpr size_t n = (sizeof(T) + 3) / 4;
  unsigned w[n] = {};
  std::memcpy(w, &x, sizeof(T));
  for (size_t i = 0; i < n; i++) w[i] = sg_shuffle_xor32(w[i], mask & 15);
  T r;
  std::memcpy(&r, w, sizeof(T));
  return r;
}
}  // namespace detail

class sub_group {
 public:
  sub_group() : lane_(0), sg_(0), nsg_(1) {}
  // lin: the work-item's local linear id, wg: the work-group size
  sub_group(size_t lin, size_t wg)
      : lane_(lin % detail::kSubGroupSize), sg_(lin / detail::kSubGroupSize), nsg_((wg + detail::kSubGroupSize - 1) / detail::kSubGroupSize) {}
  id<1> get_local_id() const { return id<1>(lane_); }
  size_t get_local_linear_id() const { return lane_; }
  range<1> get_local_range() const { return range<1>(detail::kSubGroupSize); }
  range<1> get_max_local_range() const { return range<1>(detail::kSubGroupSize); }
  size_t get_local_linear_range() const { return detail::kSubGroupSize; }
  id<1> get_group_id() const { return id<1>(sg_); }
  size_t get_group_linear_id() const { return sg_; }
  range<1> get_group_range() const { return range<1>(nsg_); }
  size_t get_group_linear_range() const { return nsg_; }
  bool leader() const { return lane_ == 0; }
  // block load and store: one element per work-item
  template <class T, access::address_space AS, access::decorated Dec> T load(multi_ptr<T, AS, Dec> p) const { return *p; }
  template <int N, class T, access::address_space AS, access::decorated Dec> vec<T, N> load(multi_ptr<T, AS, Dec> p) const {
    vec<T, N> r;
    for (int i = 0; i < N; i++) r[i] = p[i];
    return r;
  }
  template <class T> T load(const T *p) const { return *p; }
  template <class T, access::address_space AS, access::decorated Dec> void store(multi_ptr<T, AS, Dec> p, const T &x) const { *p = x; }
  template <int N, class T, access::address_space AS, access::decorated Dec> void store(multi_ptr<T, AS, Dec> p, const vec<T, N> &x) const {
    for (int i = 0; i < N; i++) p[i] = x[i];
  }
  template <class T> void store(T *p, const T &x) const { *p = x; }

 private:
  size_t lane_, sg_, nsg_;
};

template <int D = 1> class nd_item {
 public:
  nd_item() {}
  nd_item(const id<D> &gl, const id<D> &lo, const id<D> &grp, const range<D> &gr, const range<D> &lr)
      : gl_(gl), lo_(lo), grp_(grp), gr_(gr), lr_(lr) {}
  id<D> get_global_id() const { return gl_; }
  size_t get_global_id(int d) const { return gl_[d]; }
  id<D> get_local_id() const { return lo_; }
  size_t get_local_id(int d) const { return lo_[d]; }
  group<D> get_group() const {
    range<D> n;
    for (int i = 0; i < D; i++) n[i] = gr_[i] / lr_[i];
    return group<D>(grp_, lr_, n);
  }
  size_t get_group(int d) const { return grp_[d]; }
  range<D> get_group_range() const { range<D> n; for (int i = 0; i < D; i++) n[i] = gr_[i] / lr_[i]; return n; }
  size_t get_group_range(int d) const { return get_group_range()[d]; }
  size_t get_group_linear_id() const { size_t l = 0; for (int i = 0; i < D; i++) l = l * (gr_[i] / lr_[i]) + grp_[i]; return l; }
  range<D> get_global_range() const { return gr_; }
  size_t get_global_range(int d) const { return gr_[d]; }
  range<D> get_local_range() const { return lr_; }
  size_t get_local_range(int d) const { return lr_[d]; }
  size_t get_global_linear_id() const { size_t l = 0; for (int i = 0; i < D; i++) l = l * gr_[i] + gl_[i]; return l; }
  size_t get_local_linear_id() const { size_t l = 0; for (int i = 0; i < D; i++) l = l * lr_[i] + lo_[i]; return l; }
  sub_group get_sub_group() const { return sub_group(get_local_linear_id(), lr_.size()); }
  void barrier(access::fence_space = access::fence_space::global_and_local) const {
#ifdef __NFCXX_SYCL_DEVICE__
    __nfcxx_sycl_barrier();
#else
    detail::barrier_on_host();
#endif
  }

 private:
  id<D> gl_, lo_, grp_;
  range<D> gr_, lr_;
};

// the lanes of the caller's sub-group exchange values; every lane must reach each of these (the sub-group is collective)
template <class T> inline T select_from_group(sub_group, T x, id<1> i) { return detail::sg_shuffle(x, (unsigned)(i[0] & 15)); }
template <class T> inline T group_broadcast(sub_group, T x) { return detail::sg_shuffle(x, 0u); }
template <class T> inline T group_broadcast(sub_group, T x, id<1> i) { return detail::sg_shuffle(x, (unsigned)(i[0] & 15)); }
// the value of lane lane + delta (or of the caller itself when that lane is past the end)
template <class T> inline T shift_group_left(sub_group sg, T x, unsigned delta = 1) {
  unsigned lane = (unsigned)sg.get_local_linear_id();
  return detail::sg_shuffle(x, lane + delta < detail::kSubGroupSize ? lane + delta : lane);
}
// the value of lane lane - delta (or of the caller itself when that lane is before the start)
template <class T> inline T shift_group_right(sub_group sg, T x, unsigned delta = 1) {
  unsigned lane = (unsigned)sg.get_local_linear_id();
  return detail::sg_shuffle(x, lane >= delta ? lane - delta : lane);
}
template <class T> inline T permute_group_by_xor(sub_group, T x, unsigned mask) { return detail::sg_shuffle_xor(x, mask); }
// butterfly over the 16 lanes: after the xor steps 8, 4, 2, 1 every lane holds the whole sum (op commutative, as SYCL requires)
template <class T, class Op> inline T reduce_over_group(sub_group, T x, Op op) {
  for (unsigned m = detail::kSubGroupSize / 2; m > 0; m >>= 1) x = op(x, detail::sg_shuffle_xor(x, m));
  return x;
}
// Hillis-Steele: after the steps 1, 2, 4, 8 lane k holds the combination of lanes 0..k
template <class T, class Op> inline T inclusive_scan_over_group(sub_group sg, T x, Op op) {
  unsigned lane = (unsigned)sg.get_local_linear_id();
  for (unsigned d = 1; d < detail::kSubGroupSize; d <<= 1) {
    T y = shift_group_right(sg, x, d);
    if (lane >= d) x = op(y, x);
  }
  return x;
}
inline bool any_of_group(sub_group, bool p) {
  unsigned r = p ? 1u : 0u;
  for (unsigned m = detail::kSubGroupSize / 2; m > 0; m >>= 1) r |= detail::sg_shuffle_xor(r, m);
  return r != 0;
}
inline bool all_of_group(sub_group, bool p) {
  unsigned r = p ? 1u : 0u;
  for (unsigned m = detail::kSubGroupSize / 2; m > 0; m >>= 1) r &= detail::sg_shuffle_xor(r, m);
  return r != 0;
}
inline bool none_of_group(sub_group sg, bool p) { return !any_of_group(sg, p); }
inline void group_barrier(sub_group, memory_scope = memory_scope::sub_group) {
#ifdef __NFCXX_SYCL_DEVICE__
  __nfcxx_sycl_barrier();
#else
  detail::barrier_on_host();
#endif
}

template <int D> inline void group_barrier(const group<D> &, memory_scope = memory_scope::work_group) {
#ifdef __NFCXX_SYCL_DEVICE__
  __nfcxx_sycl_barrier();
#else
  detail::barrier_on_host();
#endif
}

// ------------------------------------------------------------------------------------------------ access modes

enum class access_mode { read, write, read_write, discard_write, discard_read_write, atomic };
namespace access {
using mode = ::sycl::access_mode;
enum class target { device, host_buffer, global_buffer = device, constant_buffer, local };
enum class placeholder { false_t, true_t };
}  // namespace access
enum class target { device, host_task };

template <access_mode M> struct mode_tag_t { constexpr mode_tag_t() {} };
inline constexpr mode_tag_t<access_mode::read> read_only{};
inline constexpr mode_tag_t<access_mode::write> write_only{};
inline constexpr mode_tag_t<access_mode::read_write> read_write{};
struct no_init_t { constexpr no_init_t() {} };
inline constexpr no_init_t no_init{};

namespace detail {
// whether the previous contents must be on the device (every mode but the discard ones; `write` keeps unwritten elements)
constexpr bool reads(access_mode m) { return m != access_mode::discard_write && m != access_mode::discard_read_write; }
constexpr bool writes(access_mode m) { return m != access_mode::read; }
constexpr access_mode discard(access_mode m) {
  return m == access_mode::read_write ? access_mode::discard_read_write : m == access_mode::write ? access_mode::discard_write : m;
}
}  // namespace detail

// ------------------------------------------------------------------------------------------------ properties

namespace property {
struct no_init {};
namespace queue { struct in_order {}; struct enable_profiling {}; }
namespace buffer { struct use_host_ptr {}; struct use_mutex {}; struct context_bound {}; }
namespace reduction { struct initialize_to_identity {}; }
}  // namespace property

namespace detail {
template <class P> struct is_no_init { static constexpr bool value = false; };
template <> struct is_no_init<property::no_init> { static constexpr bool value = true; };
template <class P> struct is_init_identity { static constexpr bool value = false; };
template <> struct is_init_identity<property::reduction::initialize_to_identity> { static constexpr bool value = true; };
}  // namespace detail

// Properties are accepted and, except no_init, have no effect.
class property_list {
 public:
  property_list() {}
  template <class... P> property_list(const P &...) {
    no_init_ = (false || ... || detail::is_no_init<P>::value);
    init_identity_ = (false || ... || detail::is_init_identity<P>::value);
  }
  bool no_init() const { return no_init_; }
  bool init_identity() const { return init_identity_; }

 private:
  bool no_init_ = false, init_identity_ = false;
};

// ------------------------------------------------------------------------------------------------ errors

enum class errc { success = 0, runtime, kernel, accessor, nd_range, event, invalid_parameter, device, platform, memory_allocation, feature_not_supported };
inline const std::error_category &sycl_category() noexcept {
  struct cat : std::error_category {
    const char *name() const noexcept override { return "sycl"; }
    std::string message(int) const override { return "sycl error"; }
  };
  static cat c;
  return c;
}
class exception : public std::exception {
 public:
  explicit exception(const char *what) : what_(what), code_((int)errc::runtime, sycl_category()) {}
  exception(errc c, const char *what) : what_(what), code_((int)c, sycl_category()) {}
  const char *what() const noexcept override { return what_.c_str(); }
  const std::error_code &code() const noexcept { return code_; }
  const std::error_category &category() const noexcept { return code_.category(); }

 private:
  std::string what_;
  std::error_code code_;
};
class exception_list {
 public:
  using iterator = std::vector<std::exception_ptr>::const_iterator;
  iterator begin() const { return v_.begin(); }
  iterator end() const { return v_.end(); }
  size_t size() const { return v_.size(); }

 private:
  std::vector<std::exception_ptr> v_;
};
using async_handler = std::function<void(exception_list)>;

// ------------------------------------------------------------------------------------------------ backend interface

class handler;

namespace detail {

inline void *host_alloc(unsigned long n) { return std::malloc(n); }
inline void host_free(void *p) { std::free(p); }

// Where a buffer lives and which side holds the newest data (WebGPU path; the host path only uses `host`).
struct buffer_state {
  void *host = nullptr;
  unsigned bytes = 0;
  unsigned long dev = 0;   // device address of the device copy, 0 until allocated
  bool dev_valid = false;  // the device copy holds the newest data
  bool host_valid = true;  // the host copy holds the newest data
  bool owns = false;
};

struct buffer_use {
  buffer_state *st;
  access_mode mode;
};

// The backend: a no-op on the host path, the WebGPU or Vulkan runtime otherwise (rt_pipe.hpp, rt_vulkan.hpp).
unsigned long backend_dev_offset(buffer_state &);                // allocates the device copy on first use
void backend_sync_to_host(buffer_state &);                  // waits for the device and reads the data back if it is newer
void backend_release(buffer_state &);                       // frees the device copy
void *backend_usm_alloc(unsigned long bytes, unsigned align, int kind);   // kind: 0 device, 1 shared, 2 host
void backend_usm_free(void *);
void backend_memcpy(void *dst, const void *src, unsigned long n);
void backend_memset(void *p, int v, unsigned long n);
bool backend_is_usm(const void *);
void backend_dispatch(const char *key, const void *closure, unsigned closure_bytes, const unsigned *global,
                      const unsigned *local, unsigned local_mem_bytes, buffer_use *uses, int nuses);
void backend_wait();

}  // namespace detail

}  // namespace sycl

#if defined(NFCXX_SYCL_VULKAN) && !defined(__NFCXX_SYCL_DEVICE__)
#include "rt_vulkan.hpp"
#elif defined(NFCXX_SYCL_OPENCL) && !defined(__NFCXX_SYCL_DEVICE__)
#include "rt_opencl.hpp"
#elif defined(NFCXX_SYCL_LEVEL_ZERO) && !defined(__NFCXX_SYCL_DEVICE__)
#include "rt_level_zero.hpp"
#elif defined(NFCXX_SYCL_WEBGPU) && !defined(__NFCXX_SYCL_DEVICE__)
#include "rt_pipe.hpp"
#else
namespace sycl {
namespace detail {
inline unsigned long backend_dev_offset(buffer_state &) { return 0; }
inline void backend_sync_to_host(buffer_state &) {}
inline void backend_release(buffer_state &) {}
inline void *backend_usm_alloc(unsigned long bytes, unsigned align, int) {
  if (align <= 16) return std::malloc(bytes ? bytes : 1);
  return std::aligned_alloc(align, (bytes + align - 1) / align * align);
}
inline void backend_usm_free(void *p) { std::free(p); }
inline void backend_memcpy(void *dst, const void *src, unsigned long n) { std::memmove(dst, src, n); }
inline void backend_memset(void *p, int v, unsigned long n) { std::memset(p, v, n); }
inline bool backend_is_usm(const void *) { return false; }
inline void backend_dispatch(const char *, const void *, unsigned, const unsigned *, const unsigned *, unsigned, buffer_use *, int) {}
inline void backend_wait() {}
}  // namespace detail
}  // namespace sycl
#endif

namespace sycl {

// ------------------------------------------------------------------------------------------------ atomics

// atomic_ref on 32-bit integers and floats in a buffer, USM or local memory (WebGPU core has no 64-bit atomics). Float
// add/min/max are compare-and-swap loops on the device.
template <class T, memory_order O = memory_order::relaxed, memory_scope S = memory_scope::device,
          access::address_space A = access::address_space::generic_space>
class atomic_ref {
 public:
  using value_type = T;
  explicit atomic_ref(T &r) : p_(&r) {}
#ifdef __NFCXX_SYCL_DEVICE__
  T fetch_add(T v) const {
    if constexpr (std::is_floating_point<T>::value) return (T)__nfcxx_sycl_atomic_fadd((void *)p_, (float)v);
    else return (T)__nfcxx_sycl_atomic_add((void *)p_, (int)v);
  }
  T fetch_sub(T v) const {
    if constexpr (std::is_floating_point<T>::value) return (T)__nfcxx_sycl_atomic_fadd((void *)p_, -(float)v);
    else return (T)__nfcxx_sycl_atomic_add((void *)p_, -(int)v);
  }
  T fetch_max(T v) const {
    if constexpr (std::is_floating_point<T>::value) return (T)__nfcxx_sycl_atomic_fmax((void *)p_, (float)v);
    else if constexpr (std::is_signed<T>::value) return (T)__nfcxx_sycl_atomic_max((void *)p_, (int)v);
    else return (T)__nfcxx_sycl_atomic_umax((void *)p_, (int)v);
  }
  T fetch_min(T v) const {
    if constexpr (std::is_floating_point<T>::value) return (T)__nfcxx_sycl_atomic_fmin((void *)p_, (float)v);
    else if constexpr (std::is_signed<T>::value) return (T)__nfcxx_sycl_atomic_min((void *)p_, (int)v);
    else return (T)__nfcxx_sycl_atomic_umin((void *)p_, (int)v);
  }
  T fetch_and(T v) const { return (T)__nfcxx_sycl_atomic_and((void *)p_, (int)v); }
  T fetch_or(T v) const { return (T)__nfcxx_sycl_atomic_or((void *)p_, (int)v); }
  T fetch_xor(T v) const { return (T)__nfcxx_sycl_atomic_xor((void *)p_, (int)v); }
  T exchange(T v) const { return from_bits(__nfcxx_sycl_atomic_xchg((void *)p_, bits(v))); }
  T load() const { return from_bits(__nfcxx_sycl_atomic_load((void *)p_)); }
  void store(T v) const { __nfcxx_sycl_atomic_xchg((void *)p_, bits(v)); }
  bool compare_exchange_strong(T &expected, T desired) const {
    int old = __nfcxx_sycl_atomic_cas((void *)p_, bits(expected), bits(desired));
    bool ok = old == bits(expected);
    expected = from_bits(old);
    return ok;
  }
#else
  // host path: work-items run one after another (fibers switch only at barriers), so plain operations are atomic
  T fetch_add(T v) const { T o = *p_; *p_ = o + v; return o; }
  T fetch_sub(T v) const { T o = *p_; *p_ = o - v; return o; }
  T fetch_max(T v) const { T o = *p_; if (o < v) *p_ = v; return o; }
  T fetch_min(T v) const { T o = *p_; if (v < o) *p_ = v; return o; }
  T fetch_and(T v) const { T o = *p_; *p_ = o & v; return o; }
  T fetch_or(T v) const { T o = *p_; *p_ = o | v; return o; }
  T fetch_xor(T v) const { T o = *p_; *p_ = o ^ v; return o; }
  T exchange(T v) const { T o = *p_; *p_ = v; return o; }
  T load() const { return *p_; }
  void store(T v) const { *p_ = v; }
  bool compare_exchange_strong(T &expected, T desired) const {
    T o = *p_;
    if (o == expected) { *p_ = desired; return true; }
    expected = o;
    return false;
  }
#endif
  bool compare_exchange_weak(T &expected, T desired) const { return compare_exchange_strong(expected, desired); }
  bool compare_exchange_strong(T &e, T d, memory_order, memory_order = memory_order::relaxed) const { return compare_exchange_strong(e, d); }
  bool compare_exchange_weak(T &e, T d, memory_order, memory_order = memory_order::relaxed) const { return compare_exchange_strong(e, d); }
  T operator=(T v) const { store(v); return v; }
  operator T() const { return load(); }
  T operator+=(T v) const { return fetch_add(v) + v; }
  T operator-=(T v) const { return fetch_sub(v) - v; }
  T operator++() const { return fetch_add(1) + 1; }
  T operator++(int) const { return fetch_add(1); }
  T operator--() const { return fetch_sub(1) - 1; }
  T operator--(int) const { return fetch_sub(1); }

 private:
  static int bits(T v) {
    if constexpr (std::is_floating_point<T>::value) { float f = (float)v; int i; __builtin_memcpy(&i, &f, 4); return i; }
    else return (int)v;
  }
  static T from_bits(int i) {
    if constexpr (std::is_floating_point<T>::value) { float f; __builtin_memcpy(&f, &i, 4); return (T)f; }
    else return (T)i;
  }
  T *p_;
};
// the SYCL 1.2.1 name
template <class T, access::address_space A = access::address_space::global_space> using atomic = atomic_ref<T>;

namespace detail {
// what accessor::operator[] returns: a reference, or an atomic_ref for access_mode::atomic
template <class T, access_mode M> struct elem_ref {
  using type = T &;
  static type make(T *p) { return *p; }
};
template <class T> struct elem_ref<T, access_mode::atomic> {
  using type = atomic_ref<T>;
  static type make(T *p) { return atomic_ref<T>(*p); }
};
}  // namespace detail

// ------------------------------------------------------------------------------------------------ buffers

template <class T, int D, access_mode M, access::target Tg> class accessor;
template <class T, int D, access_mode M> class host_accessor;

namespace detail {
// What buffer copies share: the host copy, the device copy and the final-data destination. The last owner syncs, writes
// back to the final data and frees both copies.
struct buffer_impl {
  buffer_state st;
  void *final_ = nullptr;
  ~buffer_impl() {
    backend_sync_to_host(st);
    backend_release(st);
    if (final_ && final_ != st.host && st.bytes) std::memcpy(final_, st.host, st.bytes);
    if (st.owns) host_free(st.host);
  }
};
}  // namespace detail

template <class T, int D = 1> class buffer {
 public:
  using value_type = T;
  buffer(const range<D> &r, const property_list & = property_list()) : impl_(new detail::buffer_impl), r_(r) {
    st().bytes = (unsigned)(r.size() * sizeof(T));
    st().host = detail::host_alloc(st().bytes ? st().bytes : 1);
    st().owns = true;
  }
  buffer(T *host, const range<D> &r, const property_list & = property_list()) : impl_(new detail::buffer_impl), r_(r) {
    st().bytes = (unsigned)(r.size() * sizeof(T));
    st().host = host;
    impl_->final_ = host;
  }
  buffer(const T *host, const range<D> &r, const property_list & = property_list()) : impl_(new detail::buffer_impl), r_(r) {  // read-only data: copied, never written back
    st().bytes = (unsigned)(r.size() * sizeof(T));
    st().host = detail::host_alloc(st().bytes ? st().bytes : 1);
    st().owns = true;
    if (st().host && host) std::memcpy(st().host, host, st().bytes);
  }
  // A container with data() and size() (std::vector, std::array): `buffer<int> b(v)`; a const one is copied.
  template <class C, class = decltype((void)static_cast<T *>(static_cast<C *>(nullptr)->data()), (void)static_cast<C *>(nullptr)->size())>
  buffer(C &c, const property_list & = property_list()) : buffer(c.data(), range<D>((size_t)c.size())) {}
  template <class C, class = decltype((void)static_cast<const T *>(static_cast<const C *>(nullptr)->data()), (void)static_cast<const C *>(nullptr)->size()),
            class = detail::enable_if_t<!std::is_same<C, buffer>::value>>
  buffer(const C &c, const property_list & = property_list()) : buffer((const T *)c.data(), range<D>((size_t)c.size())) {}
  // Copies and moves share the data (SYCL buffers have reference semantics).
  buffer(const buffer &) = default;
  buffer &operator=(const buffer &) = default;
  buffer(buffer &&) = default;
  buffer &operator=(buffer &&) = default;
  range<D> get_range() const { return r_; }
  size_t size() const { return r_.size(); }
  size_t get_count() const { return r_.size(); }
  size_t byte_size() const { return r_.size() * sizeof(T); }
  size_t get_size() const { return r_.size() * sizeof(T); }
  detail::buffer_state &state() const { return impl_->st; }
  T *host_data() const { return (T *)impl_->st.host; }
  // where the data goes when the last copy of the buffer is destroyed (the host pointer it was made from, by default)
  void set_final_data(T *p) { impl_->final_ = p; }
  void set_final_data(std::nullptr_t) { impl_->final_ = nullptr; }
  template <class Alloc> void set_final_data(std::shared_ptr<Alloc> p) { impl_->final_ = p ? (void *)p->data() : nullptr; }
  void set_write_back(bool on = true) { if (!on) impl_->final_ = nullptr; else if (!impl_->final_ && !impl_->st.owns) impl_->final_ = impl_->st.host; }
  bool is_sub_buffer() const { return false; }
  template <access_mode M = access_mode::read_write, access::target Tg = access::target::device>
  accessor<T, D, M, Tg> get_access(handler &h);
  template <access_mode M = access_mode::read_write> host_accessor<T, D, M> get_host_access();
  template <access_mode M> host_accessor<T, D, M> get_host_access(mode_tag_t<M>) { return host_accessor<T, D, M>(*this); }
  host_accessor<T, D, access_mode::read_write> get_host_access(const property_list &) { return host_accessor<T, D, access_mode::read_write>(*this); }
  template <access_mode M = access_mode::read_write, access::target Tg = access::target::device>
  accessor<T, D, M, Tg> get_access(handler &h, const range<D> &r, const id<D> &off = id<D>());
  template <access_mode M, access::target Tg = access::target::device>
  accessor<T, D, M, Tg> get_access(handler &h, mode_tag_t<M>) { return accessor<T, D, M, Tg>(*this, h); }
  template <access_mode M, access::target Tg = access::target::device>
  accessor<T, D, M, Tg> get_access(handler &h, const range<D> &r, mode_tag_t<M>, const id<D> &off = id<D>()) { return accessor<T, D, M, Tg>(*this, h, r, off); }
  template <access_mode M = access_mode::read_write, access::target Tg = access::target::host_buffer>
  host_accessor<T, D, M> get_access();   // SYCL 1.2.1 spelling of a host accessor
  void sync_for_host() const { detail::backend_sync_to_host(impl_->st); }

 private:
  detail::buffer_state &st() { return impl_->st; }
  std::shared_ptr<detail::buffer_impl> impl_;
  range<D> r_;
};

template <class T, int D> buffer(T *, range<D>) -> buffer<T, D>;
template <class T, int D> buffer(const T *, range<D>) -> buffer<T, D>;
namespace detail {
template <class C> struct container_elem { using type = typename remove_cv_ref<decltype(*static_cast<C *>(nullptr)->data())>::type; };
}
template <class C, class = decltype(static_cast<C *>(nullptr)->data())> buffer(C &) -> buffer<typename detail::container_elem<C>::type, 1>;
template <class C, class = decltype(static_cast<C *>(nullptr)->data())> buffer(C &, const property_list &) -> buffer<typename detail::container_elem<C>::type, 1>;
template <class T, int D> buffer(T *, range<D>, const property_list &) -> buffer<T, D>;

// ------------------------------------------------------------------------------------------------ accessors

namespace detail {
template <int D> inline size_t linear(const id<D> &i, const range<D> &r) {
  size_t l = 0;
  for (int k = 0; k < D; k++) l = l * r[k] + i[k];
  return l;
}
// acc[i][j][k] on a 2-D or 3-D accessor: each [] fixes one more index of the row-major offset.
template <class T, int D, int L> struct subscript {
  T *base;
  range<D> r;
  size_t idx;
  decltype(auto) operator[](size_t j) const {
    size_t next = idx * r[L] + j;
    if constexpr (L + 1 == D) return base[next];
    else return subscript<T, D, L + 1>{base, r, next};
  }
};
}  // namespace detail

class event;
template <class T, class Op> class reduction_desc;

class handler {
 public:
  handler() : nuses_(0), local_bytes_(0), nhost_(0) {}
  handler(const handler &) = delete;
  ~handler();

  template <class Name = void, int D, class F> void parallel_for(range<D> r, F f);
  template <class Name = void, class F> void parallel_for(size_t n, F f) { parallel_for<Name>(range<1>(n), f); }
  template <class Name = void, int D, class F> void parallel_for(nd_range<D> r, F f);
  template <class Name = void, class F> void single_task(F f);
  template <class Name = void, int D, class T, class Op, class F> void parallel_for(range<D> r, reduction_desc<T, Op> red, F f);
  template <class Name = void, int D, class T, class Op, class F> void parallel_for(nd_range<D> r, reduction_desc<T, Op> red, F f);
  template <class Name = void, int D, class T1, class O1, class T2, class O2, class F>
  void parallel_for(range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, F f);
  template <class Name = void, int D, class T1, class O1, class T2, class O2, class F>
  void parallel_for(nd_range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, F f);
  template <class Name = void, int D, class T1, class O1, class T2, class O2, class T3, class O3, class F>
  void parallel_for(range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, reduction_desc<T3, O3> r3, F f);
  template <class Name = void, int D, class T1, class O1, class T2, class O2, class T3, class O3, class F>
  void parallel_for(nd_range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, reduction_desc<T3, O3> r3, F f);

  void depends_on(const event &) {}
  template <class V> void depends_on(const V &) {}
  void require(...) {}
  template <class F> void host_task(F f) { detail::backend_wait(); f(); }
  void memcpy(void *dst, const void *src, size_t n) { detail::backend_memcpy(dst, src, n); }
  void memset(void *p, int v, size_t n) { detail::backend_memset(p, v, n); }
  template <class T> void fill(void *p, const T &v, size_t count) {
    std::vector<T> tmp(count, v);
    detail::backend_memcpy(p, tmp.data(), count * sizeof(T));
  }
  template <class T, int D, access_mode M, access::target Tg, class V> void fill(accessor<T, D, M, Tg> a, const V &v) {
    detail::buffer_state *st = state_of(a.host_);
    if (st) detail::backend_sync_to_host(*st);
    for (size_t i = 0; i < a.size(); i++) a.host_[i] = (T)v;
    if (st) { st->host_valid = true; st->dev_valid = false; }
  }
  template <class T, int D, access_mode M, access::target Tg> void copy(accessor<T, D, M, Tg> a, T *dst) {
    detail::buffer_state *st = state_of(a.host_);
    if (st) detail::backend_sync_to_host(*st);
    std::memcpy(dst, a.host_, a.size() * sizeof(T));
  }
  template <class T, int D, access_mode M, access::target Tg> void copy(const T *src, accessor<T, D, M, Tg> a) {
    detail::buffer_state *st = state_of(a.host_);
    if (st) detail::backend_sync_to_host(*st);
    std::memcpy(a.host_, src, a.size() * sizeof(T));
    if (st) { st->host_valid = true; st->dev_valid = false; }
  }
  template <class T, int D, access_mode M, access::target Tg> void update_host(accessor<T, D, M, Tg> a) {
    detail::buffer_state *st = state_of(a.host_);
    if (st) detail::backend_sync_to_host(*st);
  }

  // internal
  detail::buffer_state *state_of(const void *host) {
    for (int i = 0; i < nuses_; i++) if (uses_[i].st->host == host) return uses_[i].st;
    return nullptr;
  }
  void use(detail::buffer_state *s, access_mode m) {
    for (int i = 0; i < nuses_; i++)
      if (uses_[i].st == s) {
        if (detail::writes(m)) uses_[i].mode = access_mode::read_write;
        return;
      }
    if (nuses_ < 16) { uses_[nuses_].st = s; uses_[nuses_].mode = m; nuses_++; }
  }
  unsigned alloc_local(unsigned bytes, unsigned align, void **host_mem) {
    local_bytes_ = (local_bytes_ + align - 1) / align * align;
    unsigned off = local_bytes_;
    local_bytes_ += bytes;
    *host_mem = nullptr;
#ifndef __NFCXX_SYCL_DEVICE__
    if (nhost_ < 8) { host_[nhost_] = detail::host_alloc(bytes ? bytes : 1); *host_mem = host_[nhost_]; nhost_++; }
#endif
    return off;
  }

 private:
  detail::buffer_use uses_[16];
  int nuses_;
  unsigned local_bytes_;
  void *host_[8];
  int nhost_;
};

inline handler::~handler() { for (int i = 0; i < nhost_; i++) detail::host_free(host_[i]); }

// The device side of an accessor: its buffer's device offset. The fields are the same on both sides.
template <class T, int D = 1, access_mode M = access_mode::read_write, access::target Tg = access::target::device>
class accessor {
 public:
  using value_type = T;
  using reference = T &;
  accessor() : host_(nullptr), dev_(0), r_() {}
  accessor(buffer<T, D> &b, handler &h) : host_(b.host_data()), dev_(detail::backend_dev_offset(b.state())), r_(b.get_range()) {
    h.use(&b.state(), M);
  }
  accessor(buffer<T, D> &b, handler &h, mode_tag_t<M>) : accessor(b, h) {}
  accessor(buffer<T, D> &b, handler &h, no_init_t) : host_(b.host_data()), dev_(detail::backend_dev_offset(b.state())), r_(b.get_range()) {
    h.use(&b.state(), detail::discard(M));
  }
  accessor(buffer<T, D> &b, handler &h, mode_tag_t<M>, no_init_t) : accessor(b, h, no_init) {}
  accessor(buffer<T, D> &b, handler &h, const property_list &pl) : host_(b.host_data()), dev_(detail::backend_dev_offset(b.state())), r_(b.get_range()) {
    h.use(&b.state(), pl.no_init() ? detail::discard(M) : M);
  }
  accessor(buffer<T, D> &b, handler &h, mode_tag_t<M>, const property_list &pl) : accessor(b, h, pl) {}
  // a range and an offset: the part of a one-dimensional buffer the accessor covers (indexes start at the offset's element)
  accessor(buffer<T, D> &b, handler &h, const range<D> &r, const id<D> &off = id<D>())
      : host_(b.host_data() + off[0]), dev_(detail::backend_dev_offset(b.state()) + (unsigned long)(off[0] * sizeof(T))), r_(r) {
    static_assert(D == 1, "a ranged accessor needs a one-dimensional buffer here");
    h.use(&b.state(), M);
  }
  accessor(buffer<T, D> &b, handler &h, const range<D> &r, mode_tag_t<M>, const id<D> &off = id<D>()) : accessor(b, h, r, off) {}
  size_t size() const { return r_.size(); }
  size_t get_count() const { return r_.size(); }
  range<D> get_range() const { return r_; }
  typename detail::elem_ref<T, M>::type operator[](const id<D> &i) const { return detail::elem_ref<T, M>::make(base() + detail::linear<D>(i, r_)); }
  typename detail::elem_ref<T, M>::type operator[](const item<D> &i) const { return detail::elem_ref<T, M>::make(base() + detail::linear<D>(i.get_id(), r_)); }
  template <int E = D, class = detail::enable_if_t<E == 1>> typename detail::elem_ref<T, M>::type operator[](size_t i) const { return detail::elem_ref<T, M>::make(base() + i); }
  template <int E = D, class = detail::enable_if_t<(E > 1)>> detail::subscript<T, D, 1> operator[](size_t i) const { return detail::subscript<T, D, 1>{base(), r_, i}; }
  template <access::decorated Dec = access::decorated::legacy> global_ptr<T, Dec> get_multi_ptr() const { return global_ptr<T, Dec>(base()); }
  size_t get_size() const { return r_.size() * sizeof(T); }
  size_t byte_size() const { return r_.size() * sizeof(T); }
  id<D> get_offset() const { return id<D>(); }
  bool is_placeholder() const { return false; }
  T *get_pointer() const { return base(); }
  T *begin() const { return base(); }
  T *end() const { return base() + r_.size(); }

  T *host_;
  unsigned long dev_;
  range<D> r_;

 private:
#ifdef __NFCXX_SYCL_DEVICE__
  T *base() const { return (T *)(unsigned long)dev_; }
#else
  T *base() const { return host_; }
#endif
};

template <class T, int D, access_mode M> accessor(buffer<T, D> &, handler &, mode_tag_t<M>) -> accessor<T, D, M, access::target::device>;
template <class T, int D, access_mode M> accessor(buffer<T, D> &, handler &, mode_tag_t<M>, no_init_t) -> accessor<T, D, M, access::target::device>;
template <class T, int D> accessor(buffer<T, D> &, handler &) -> accessor<T, D, access_mode::read_write, access::target::device>;
template <class T, int D> accessor(buffer<T, D> &, handler &, no_init_t) -> accessor<T, D, access_mode::discard_write, access::target::device>;
template <class T, int D> accessor(buffer<T, D> &, handler &, const property_list &) -> accessor<T, D, access_mode::read_write, access::target::device>;
template <class T, int D, access_mode M> accessor(buffer<T, D> &, handler &, mode_tag_t<M>, const property_list &) -> accessor<T, D, M, access::target::device>;

template <class T, int D> template <access_mode M, access::target Tg>
accessor<T, D, M, Tg> buffer<T, D>::get_access(handler &h) {
  return accessor<T, D, M, Tg>(*this, h);
}
template <class T, int D> template <access_mode M, access::target Tg>
accessor<T, D, M, Tg> buffer<T, D>::get_access(handler &h, const range<D> &r, const id<D> &off) {
  return accessor<T, D, M, Tg>(*this, h, r, off);
}

// A host accessor: constructing it waits for the device and copies newer data back.
template <class T, int D = 1, access_mode M = access_mode::read_write>
class host_accessor {
 public:
  host_accessor(buffer<T, D> &b) : b_(&b) { b.sync_for_host(); }
  host_accessor(buffer<T, D> &b, mode_tag_t<M>) : b_(&b) { b.sync_for_host(); }
  host_accessor(buffer<T, D> &b, const property_list &) : b_(&b) { b.sync_for_host(); }
  host_accessor(const host_accessor &o) : b_(o.b_) {}
  ~host_accessor() {
    if (detail::writes(M)) { b_->state().host_valid = true; b_->state().dev_valid = false; }
  }
  T &operator[](const id<D> &i) const { return b_->host_data()[detail::linear<D>(i, b_->get_range())]; }
  T &operator[](const item<D> &i) const { return b_->host_data()[detail::linear<D>(i.get_id(), b_->get_range())]; }
  template <int E = D, class = detail::enable_if_t<E == 1>> T &operator[](size_t i) const { return b_->host_data()[i]; }
  template <int E = D, class = detail::enable_if_t<(E > 1)>> detail::subscript<T, D, 1> operator[](size_t i) const {
    return detail::subscript<T, D, 1>{b_->host_data(), b_->get_range(), i};
  }
  size_t size() const { return b_->size(); }
  size_t get_count() const { return b_->size(); }
  range<D> get_range() const { return b_->get_range(); }
  T *get_pointer() const { return b_->host_data(); }
  T *begin() const { return b_->host_data(); }
  T *end() const { return b_->host_data() + b_->size(); }

 private:
  buffer<T, D> *b_;
};
template <class T, int D> template <access_mode M> host_accessor<T, D, M> buffer<T, D>::get_host_access() { return host_accessor<T, D, M>(*this); }
template <class T, int D> template <access_mode M, access::target Tg> host_accessor<T, D, M> buffer<T, D>::get_access() { return host_accessor<T, D, M>(*this); }
template <class T, int D, access_mode M> host_accessor(buffer<T, D> &, mode_tag_t<M>) -> host_accessor<T, D, M>;
template <class T, int D> host_accessor(buffer<T, D> &) -> host_accessor<T, D, access_mode::read_write>;

// Work-group local memory: a slice of the group's memory, assigned by the handler.
template <class T, int D = 1> class local_accessor {
 public:
  local_accessor() : off_(0), r_(), host_local_(nullptr) {}
  local_accessor(const range<D> &r, handler &h) : off_(0), r_(r), host_local_(nullptr) {
    void *hm;
    off_ = h.alloc_local((unsigned)(r.size() * sizeof(T)), (unsigned)(sizeof(T) < 4 ? 4 : sizeof(T)), &hm);
    host_local_ = (T *)hm;
  }
  T &operator[](const id<D> &i) const { return base()[detail::linear<D>(i, r_)]; }
  T &operator[](const item<D> &i) const { return base()[detail::linear<D>(i.get_id(), r_)]; }
  template <int E = D, class = detail::enable_if_t<E == 1>> T &operator[](size_t i) const { return base()[i]; }
  template <int E = D, class = detail::enable_if_t<(E > 1)>> detail::subscript<T, D, 1> operator[](size_t i) const { return detail::subscript<T, D, 1>{base(), r_, i}; }
  size_t size() const { return r_.size(); }
  size_t get_count() const { return r_.size(); }
  range<D> get_range() const { return r_; }
  T *get_pointer() const { return base(); }
  template <access::decorated Dec = access::decorated::legacy> local_ptr<T, Dec> get_multi_ptr() const { return local_ptr<T, Dec>(base()); }

 private:
#ifdef __NFCXX_SYCL_DEVICE__
  T *base() const { return (T *)((unsigned long)__nfcxx_sycl_local_base() + off_); }
#else
  T *base() const { return host_local_; }
#endif
  unsigned off_;
  range<D> r_;
  T *host_local_;
};

#ifndef __NFCXX_SYCL_DEVICE__
// ---- barriers on the host path. The work-items of a group run as fibers (ucontext) so that barrier() can stop one until
// all have arrived: the scheduler runs each fiber to its next barrier or to its end, round after round. A group of one
// work-item runs directly, and its barriers do nothing.
#ifndef NFCXX_SYCL_FIBER_STACK
#define NFCXX_SYCL_FIBER_STACK (96 * 1024)
#endif
namespace detail {
// The item of a work-item on the host: its nd_item<dim> (set by the kernel's body while the fiber runs), and its local
// linear id and group size, which get_sub_group() needs without the dimension.
struct host_item {
  const void *nd = nullptr;
  int dim = 0;
  size_t lin = 0, wg = 1;
};
struct host_group {
  int n = 0, cur = 0;
  ucontext_t sched;
  std::vector<ucontext_t> ctx;
  std::vector<char *> stacks;
  std::vector<char> done;
  std::vector<unsigned long> scratch;   // one word per work-item, for the group algorithms
  std::vector<host_item> items;         // one per work-item
  void (*run)(void *, int) = nullptr;
  void *arg = nullptr;
};
inline host_group *&current_group() {
  static host_group *g = nullptr;
  return g;
}
// The item of the work-item that is running: the scheduler points it at that fiber's slot before each switch into the fiber.
inline host_item *&current_host_item() {
  static thread_local host_item *p = nullptr;
  return p;
}
inline void fiber_main() {
  host_group *g = current_group();
  int idx = g->cur;
  g->run(g->arg, idx);
  g->done[idx] = 1;   // returning resumes uc_link, the scheduler
}
inline void barrier_on_host() {
  host_group *g = current_group();
  if (g) swapcontext(&g->ctx[g->cur], &g->sched);
}
// Runs body(i) for i < n as the n work-items of one group, with barriers working.
template <class Body> inline void run_group_items(host_group &g, int n, Body &body) {
  g.items.assign(n, host_item{});
  for (int i = 0; i < n; i++) { g.items[i].lin = (size_t)i; g.items[i].wg = (size_t)n; }
  host_item *saved_item = current_host_item();
  if (n == 1) {
    current_host_item() = &g.items[0];
    body(0);
    current_host_item() = saved_item;
    return;
  }
  g.run = [](void *a, int i) { (*(Body *)a)(i); };
  g.arg = &body;
  g.n = n;
  if ((int)g.ctx.size() < n) {
    g.ctx.resize(n);
    g.done.resize(n);
    g.scratch.resize(n);
    while ((int)g.stacks.size() < n) g.stacks.push_back((char *)std::malloc(NFCXX_SYCL_FIBER_STACK));
  }
  for (int i = 0; i < n; i++) {
    g.done[i] = 0;
    getcontext(&g.ctx[i]);
    g.ctx[i].uc_stack.ss_sp = g.stacks[i];
    g.ctx[i].uc_stack.ss_size = NFCXX_SYCL_FIBER_STACK;
    g.ctx[i].uc_link = &g.sched;
    makecontext(&g.ctx[i], (void (*)())fiber_main, 0);
  }
  host_group *saved = current_group();
  current_group() = &g;
  int left = n;
  while (left > 0)
    for (int i = 0; i < n; i++) {
      if (g.done[i]) continue;
      g.cur = i;
      current_host_item() = &g.items[i];
      swapcontext(&g.sched, &g.ctx[i]);
      if (g.done[i]) left--;
    }
  current_host_item() = saved_item;
  current_group() = saved;
}
inline void free_group(host_group &g) { for (char *s : g.stacks) std::free(s); g.stacks.clear(); }
// sub-group exchanges on the host: each work-item writes its word, a barrier, reads its source's word, a barrier (so the next
// write waits until every read is done). The lanes of a sub-group are the work-items 16j..16j+15 of the group (g->cur is the index).
inline unsigned sg_shuffle32(unsigned w, unsigned src) {
  host_group *g = current_group();
  if (!g) return w;
  int cur = g->cur, from = (cur & ~15) + (int)(src & 15);
  g->scratch[cur] = w;
  barrier_on_host();
  unsigned r = from < g->n ? (unsigned)g->scratch[from] : w;
  barrier_on_host();
  return r;
}
inline unsigned sg_shuffle_xor32(unsigned w, unsigned mask) {
  host_group *g = current_group();
  if (!g) return w;
  return sg_shuffle32(w, (unsigned)(g->cur & 15) ^ (mask & 15));
}
}  // namespace detail
#else
namespace detail {
inline void barrier_on_host() {}   // never called on the device: nd_item::barrier lowers to __nfcxx_sycl_barrier
inline unsigned sg_shuffle32(unsigned w, unsigned src) { return __nfcxx_sycl_sg_shuffle_u32(w, src & 15); }
inline unsigned sg_shuffle_xor32(unsigned w, unsigned mask) { return __nfcxx_sycl_sg_shuffle_xor_u32(w, mask & 15); }
}  // namespace detail
#endif

// ------------------------------------------------------------------------------------------------ launching

namespace detail {

#ifdef __NFCXX_SYCL_DEVICE__
template <int D> inline range<D> device_global_range();
template <> inline range<1> device_global_range<1>() { return range<1>(__nfcxx_sycl_grange_x()); }
template <> inline range<2> device_global_range<2>() { return range<2>(__nfcxx_sycl_grange_x(), __nfcxx_sycl_grange_y()); }
template <> inline range<3> device_global_range<3>() { return range<3>(__nfcxx_sycl_grange_x(), __nfcxx_sycl_grange_y(), __nfcxx_sycl_grange_z()); }
template <int D> inline range<D> device_local_range();
template <> inline range<1> device_local_range<1>() { return range<1>(__nfcxx_sycl_lrange_x()); }
template <> inline range<2> device_local_range<2>() { return range<2>(__nfcxx_sycl_lrange_x(), __nfcxx_sycl_lrange_y()); }
template <> inline range<3> device_local_range<3>() { return range<3>(__nfcxx_sycl_lrange_x(), __nfcxx_sycl_lrange_y(), __nfcxx_sycl_lrange_z()); }
template <int D> inline id<D> device_gid();
template <> inline id<1> device_gid<1>() { return id<1>(__nfcxx_sycl_gid_x()); }
template <> inline id<2> device_gid<2>() { return id<2>(__nfcxx_sycl_gid_x(), __nfcxx_sycl_gid_y()); }
template <> inline id<3> device_gid<3>() { return id<3>(__nfcxx_sycl_gid_x(), __nfcxx_sycl_gid_y(), __nfcxx_sycl_gid_z()); }
template <int D> inline id<D> device_lid();
template <> inline id<1> device_lid<1>() { return id<1>(__nfcxx_sycl_lid_x()); }
template <> inline id<2> device_lid<2>() { return id<2>(__nfcxx_sycl_lid_x(), __nfcxx_sycl_lid_y()); }
template <> inline id<3> device_lid<3>() { return id<3>(__nfcxx_sycl_lid_x(), __nfcxx_sycl_lid_y(), __nfcxx_sycl_lid_z()); }
template <int D> inline id<D> device_group();
template <> inline id<1> device_group<1>() { return id<1>(__nfcxx_sycl_group_x()); }
template <> inline id<2> device_group<2>() { return id<2>(__nfcxx_sycl_group_x(), __nfcxx_sycl_group_y()); }
template <> inline id<3> device_group<3>() { return id<3>(__nfcxx_sycl_group_x(), __nfcxx_sycl_group_y(), __nfcxx_sycl_group_z()); }

// Kernel entries. The WGSL emitter turns each function whose name contains __nfcxx_sycl_entry_ into a compute entry point.
// The closure's type, found from the cast of __nfcxx_sycl_closure(), names the kernel for the host.
template <int D, class F> void __nfcxx_sycl_entry_range() {
  const F *f = (const F *)__nfcxx_sycl_closure();
  range<D> r = device_global_range<D>();
  id<D> g = device_gid<D>();
  for (int d = 0; d < D; d++)
    if (g[d] >= r[d]) return;
  (*f)(item<D>(g, r));
}
template <int D, class F> void __nfcxx_sycl_entry_nd() {
  const F *f = (const F *)__nfcxx_sycl_closure();
  (*f)(nd_item<D>(device_gid<D>(), device_lid<D>(), device_group<D>(), device_global_range<D>(), device_local_range<D>()));
}
template <class F> void __nfcxx_sycl_entry_single() {
  const F *f = (const F *)__nfcxx_sycl_closure();
  if (__nfcxx_sycl_gid_x() == 0) (*f)();
}
#endif

template <int D> inline unsigned default_local(int d) { return D == 1 ? (d == 0 ? 64u : 1u) : D == 2 ? (d < 2 ? 8u : 1u) : 4u; }

}  // namespace detail

template <class Name, int D, class F> void handler::parallel_for(range<D> r, F f) {
#ifdef __NFCXX_SYCL_DEVICE__
  detail::__nfcxx_sycl_entry_range<D, F>();  // never run: it makes the device pass lower the entry
  (void)r;
#elif defined(NFCXX_SYCL_GPU)
  unsigned g[3] = {1, 1, 1}, l[3] = {1, 1, 1};
  for (int d = 0; d < D; d++) { g[d] = (unsigned)r[d]; l[d] = detail::default_local<D>(d); }
  detail::backend_dispatch(typeid(F).name(), &f, (unsigned)sizeof(F), g, l, local_bytes_, uses_, nuses_);
#else
  range<D> rr = r;
  size_t n = rr.size();
  for (size_t lin = 0; lin < n; lin++) {
    id<D> i;
    size_t t = lin;
    for (int d = D - 1; d >= 0; d--) { i[d] = t % rr[d]; t /= rr[d]; }
    f(item<D>(i, rr));
  }
#endif
}

template <class Name, int D, class F> void handler::parallel_for(nd_range<D> r, F f) {
#ifdef __NFCXX_SYCL_DEVICE__
  detail::__nfcxx_sycl_entry_nd<D, F>();
  (void)r;
#elif defined(NFCXX_SYCL_GPU)
  unsigned g[3] = {1, 1, 1}, l[3] = {1, 1, 1};
  for (int d = 0; d < D; d++) { g[d] = (unsigned)r.get_global_range()[d]; l[d] = (unsigned)r.get_local_range()[d]; }
  detail::backend_dispatch(typeid(F).name(), &f, (unsigned)sizeof(F), g, l, local_bytes_, uses_, nuses_);
#else
  // The groups run one after another; the work-items of a group are fibers, so barrier() and the group algorithms work.
  range<D> gr = r.get_global_range(), lr = r.get_local_range();
  size_t ngroups = 1, nlocal = lr.size();
  for (int d = 0; d < D; d++) ngroups *= gr[d] / lr[d];
  detail::host_group hg;
  for (size_t gl = 0; gl < ngroups; gl++) {
    auto body = [&](int ll) {
      id<D> grp, loc, glo;
      size_t tg = gl, tl = (size_t)ll;
      for (int d = D - 1; d >= 0; d--) {
        grp[d] = tg % (gr[d] / lr[d]); tg /= gr[d] / lr[d];
        loc[d] = tl % lr[d]; tl /= lr[d];
        glo[d] = grp[d] * lr[d] + loc[d];
      }
      nd_item<D> it(glo, loc, grp, gr, lr);
      detail::host_item &hi = hg.items[ll];
      hi.nd = &it;
      hi.dim = D;
      f(it);
      hi.nd = nullptr;
    };
    detail::run_group_items(hg, (int)nlocal, body);
  }
  detail::free_group(hg);
#endif
}

template <class Name, class F> void handler::single_task(F f) {
#ifdef __NFCXX_SYCL_DEVICE__
  detail::__nfcxx_sycl_entry_single<F>();
#elif defined(NFCXX_SYCL_GPU)
  unsigned g[3] = {1, 1, 1}, l[3] = {1, 1, 1};
  detail::backend_dispatch(typeid(F).name(), &f, (unsigned)sizeof(F), g, l, local_bytes_, uses_, nuses_);
#else
  f();
#endif
}

// ------------------------------------------------------------------------------------------------ this_work_item
// The item of the work-item that is running. On the device it is built from the builtins the kernel's item comes from. On
// the host it is the item of the running fiber (detail::current_host_item, set by the scheduler in run_group_items).
namespace ext::oneapi::this_work_item {
template <int D> inline nd_item<D> get_nd_item() {
#ifdef __NFCXX_SYCL_DEVICE__
  return nd_item<D>(detail::device_gid<D>(), detail::device_lid<D>(), detail::device_group<D>(), detail::device_global_range<D>(),
                    detail::device_local_range<D>());
#else
  const detail::host_item *h = detail::current_host_item();
  if (!h || !h->nd || h->dim != D) {
    std::fprintf(stderr, "this_work_item::get_nd_item<%d>: no nd_range work-item is running\n", D);
    std::abort();
  }
  return *static_cast<const nd_item<D> *>(h->nd);
#endif
}
inline sub_group get_sub_group() {
#ifdef __NFCXX_SYCL_DEVICE__
  return get_nd_item<3>().get_sub_group();   // unused dimensions have range 1 and id 0, so the linear id and size are the kernel's
#else
  const detail::host_item *h = detail::current_host_item();
  if (!h) {
    std::fprintf(stderr, "this_work_item::get_sub_group: no nd_range work-item is running\n");
    std::abort();
  }
  return sub_group(h->lin, h->wg);
#endif
}
}  // namespace ext::oneapi::this_work_item

// ------------------------------------------------------------------------------------------------ device, platform, context

enum class aspect {
  cpu, gpu, accelerator, custom, emulated, host_debuggable, fp16, fp64, atomic64, image, online_compiler, online_linker,
  queue_profiling, usm_device_allocations, usm_host_allocations, usm_atomic_host_allocations, usm_shared_allocations,
  usm_atomic_shared_allocations, usm_system_allocations
};

namespace info {
enum class device_type { cpu, gpu, accelerator, custom, automatic, host, all };
enum class event_command_status { submitted, running, complete };
namespace device {
struct name {};
struct vendor {};
struct driver_version {};
struct version {};
struct device_type {};
struct max_work_group_size {};
struct max_work_item_dimensions {};
struct max_compute_units {};
struct global_mem_size {};
struct global_mem_cache_size {};
struct mem_base_addr_align {};
struct local_mem_size {};
struct max_mem_alloc_size {};
struct sub_group_sizes {};
struct profile {};
struct opencl_c_version {};
struct max_clock_frequency {};
struct address_bits {};
struct is_available {};
struct usm_device_allocations {};
struct usm_host_allocations {};
struct usm_shared_allocations {};
struct usm_system_allocations {};
struct error_correction_support {};
struct partition_max_sub_devices {};
struct partition_properties {};
struct native_vector_width_char {};
struct native_vector_width_short {};
struct native_vector_width_int {};
struct native_vector_width_long {};
struct native_vector_width_float {};
struct native_vector_width_double {};
struct native_vector_width_half {};
struct preferred_vector_width_float {};
struct preferred_vector_width_int {};
struct local_mem_type {};
template <int D> struct max_work_item_sizes {};
struct max_num_sub_groups {};
struct image_support {};
struct atomic_memory_order_capabilities {};
}  // namespace device
enum class local_mem_type { none, local, global };
enum class partition_affinity_domain { not_applicable, numa, L4_cache, L3_cache, L2_cache, L1_cache, next_partitionable };
enum class partition_property { no_partition, partition_equally, partition_by_counts, partition_by_affinity_domain };
namespace event_profiling {
struct command_submit {};
struct command_start {};
struct command_end {};
}  // namespace event_profiling
namespace queue {
struct context {};
struct device {};
}  // namespace queue
namespace platform {
struct name {};
struct vendor {};
struct version {};
struct profile {};
}  // namespace platform
}  // namespace info

struct default_selector_t {};
struct cpu_selector_t {};
struct gpu_selector_t {};
struct accelerator_selector_t {};
inline constexpr default_selector_t default_selector_v{};
inline constexpr cpu_selector_t cpu_selector_v{};
inline constexpr gpu_selector_t gpu_selector_v{};
inline constexpr accelerator_selector_t accelerator_selector_v{};
// SYCL 1.2.1 selector classes
struct default_selector {};
struct cpu_selector {};
struct gpu_selector {};
struct accelerator_selector {};

class platform;
class device {
 public:
  device() {}
  template <class S> device(const S &) {}
  backend get_backend() const { return is_gpu() ? backend::opencl : backend::host; }
  bool is_gpu() const {
#ifdef NFCXX_SYCL_GPU
    return true;
#else
    return false;
#endif
  }
  bool is_cpu() const { return !is_gpu(); }
  bool is_accelerator() const { return false; }
  bool has(aspect a) const {
    switch (a) {
      case aspect::gpu: return is_gpu();
      case aspect::cpu: return is_cpu();
      case aspect::fp64: return !is_gpu();
      case aspect::usm_device_allocations:
      case aspect::usm_host_allocations:
      case aspect::usm_shared_allocations: return true;
      case aspect::fp16: return has_fp16();
      default: return false;
    }
  }
  platform get_platform() const;
  template <class P> std::vector<device> create_sub_devices(P) const { throw exception(errc::feature_not_supported, "sycl: devices cannot be partitioned"); }
  static std::vector<device> get_devices(info::device_type = info::device_type::all) { return std::vector<device>(1); }
  template <class P> auto get_info() const { return info_of(static_cast<P *>(nullptr)); }

 private:
  // fp16 is a property of the backend device: the host has it (emulated), a GPU has it when its runtime reports it
  bool has_fp16() const {
    if (!is_gpu()) return true;
#if defined(NFCXX_SYCL_OPENCL) && !defined(__NFCXX_SYCL_DEVICE__)
    return detail::cl_rt::get().has_fp16();
#elif defined(NFCXX_SYCL_LEVEL_ZERO) && !defined(__NFCXX_SYCL_DEVICE__)
    return detail::ze_rt::get().has_fp16();
#else
    return false;  // WebGPU and Vulkan: no fp16 query in this subset
#endif
  }
  std::string info_of(info::device::name *) const {
    if (!is_gpu()) return "nfcxx host";
#if defined(NFCXX_SYCL_OPENCL) && !defined(__NFCXX_SYCL_DEVICE__)
    return detail::cl_rt::get().device_name();
#elif defined(NFCXX_SYCL_LEVEL_ZERO) && !defined(__NFCXX_SYCL_DEVICE__)
    return detail::ze_rt::get().device_name();
#elif defined(NFCXX_SYCL_VULKAN) && !defined(__NFCXX_SYCL_DEVICE__)
    return detail::vk_rt::get().device_name();
#else
    return "nfcxx WebGPU";
#endif
  }
  std::string info_of(info::device::vendor *) const { return "nfcxx"; }
  std::string info_of(info::device::driver_version *) const { return "0"; }
  std::string info_of(info::device::version *) const { return "SYCL 2020 subset"; }
  info::device_type info_of(info::device::device_type *) const { return is_gpu() ? info::device_type::gpu : info::device_type::cpu; }
  size_t info_of(info::device::max_work_group_size *) const { return is_gpu() ? 256 : 1024; }
  unsigned info_of(info::device::max_work_item_dimensions *) const { return 3; }
  unsigned info_of(info::device::max_compute_units *) const { return 1; }
  unsigned long info_of(info::device::global_mem_size *) const { return is_gpu() ? (1ul << 28) : (1ul << 32); }
  unsigned long info_of(info::device::global_mem_cache_size *) const { return 1ul << 20; }
  unsigned info_of(info::device::mem_base_addr_align *) const { return 1024; }
  friend bool operator==(const device &, const device &) { return true; }   // one device in this subset
  unsigned long info_of(info::device::local_mem_size *) const { return 16384; }
  unsigned long info_of(info::device::max_mem_alloc_size *) const { return is_gpu() ? (1ul << 28) : (1ul << 32); }
  std::vector<size_t> info_of(info::device::sub_group_sizes *) const { return std::vector<size_t>(1, detail::kSubGroupSize); }
  info::local_mem_type info_of(info::device::local_mem_type *) const { return info::local_mem_type::local; }
  template <int D> id<3> info_of(info::device::max_work_item_sizes<D> *) const { return id<3>(256, 256, 64); }
  std::string info_of(info::device::profile *) const { return "FULL_PROFILE"; }
  std::vector<info::partition_property> info_of(info::device::partition_properties *) const { return std::vector<info::partition_property>(); }
  unsigned info_of(info::device::partition_max_sub_devices *) const { return 0; }
  bool info_of(info::device::is_available *) const { return true; }
  bool info_of(info::device::usm_device_allocations *) const { return true; }
  bool info_of(info::device::usm_host_allocations *) const { return true; }
  bool info_of(info::device::usm_shared_allocations *) const { return true; }
  bool info_of(info::device::usm_system_allocations *) const { return false; }
  // the other descriptors: a number, 0 where the question has no meaning here
  template <class P> unsigned long info_of(P *) const { return 0; }
};

class platform {
 public:
  platform() {}
  template <class S> platform(const S &) {}
  static std::vector<platform> get_platforms() { return std::vector<platform>(1); }
  std::vector<device> get_devices(info::device_type = info::device_type::all) const { return std::vector<device>(1); }
  template <class P> std::string get_info() const { return "nfcxx"; }
};
inline platform device::get_platform() const { return platform(); }

class context {
 public:
  context() {}
  template <class... A> context(const A &...) {}
  platform get_platform() const { return platform(); }
  std::vector<device> get_devices() const { return std::vector<device>(1); }
};

namespace detail {
inline unsigned long now_ns() {
  return (unsigned long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
}  // namespace detail

// Profiling times are host clock readings: the submission, the end of the host-side enqueue, and the moment the work was
// known to be done (the first wait).
class event {
 public:
  event() : t_submit_(detail::now_ns()), t_start_(t_submit_), t_end_(0) {}
  void wait() const { detail::backend_wait(); finish(); }
  void wait_and_throw() const { wait(); }
  static void wait(const std::vector<event> &v) { detail::backend_wait(); for (const event &e : v) e.finish(); }
  static void wait_and_throw(const std::vector<event> &v) { wait(v); }
  template <class P> unsigned long get_profiling_info() const { return profiling_of(static_cast<P *>(nullptr)); }
  void mark_started() { t_start_ = detail::now_ns(); }
  info::event_command_status get_info_status() const { return info::event_command_status::complete; }

 private:
  unsigned long profiling_of(info::event_profiling::command_submit *) const { return t_submit_; }
  unsigned long profiling_of(info::event_profiling::command_start *) const { return t_start_; }
  unsigned long profiling_of(info::event_profiling::command_end *) const { finish(); return t_end_; }
  void finish() const { if (!t_end_) { detail::backend_wait(); t_end_ = detail::now_ns(); } }
  unsigned long t_submit_, t_start_;
  mutable unsigned long t_end_;
};

// ------------------------------------------------------------------------------------------------ reductions

template <class T = void> struct plus {
  static constexpr int red_kind = 0;
  T operator()(const T &a, const T &b) const { return a + b; }
};
template <> struct plus<void> {
  static constexpr int red_kind = 0;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a + b; }
};
template <class T = void> struct multiplies {
  static constexpr int red_kind = 1;
  T operator()(const T &a, const T &b) const { return a * b; }
};
template <> struct multiplies<void> {
  static constexpr int red_kind = 1;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a * b; }
};
template <class T = void> struct minimum {
  static constexpr int red_kind = 2;
  T operator()(const T &a, const T &b) const { return b < a ? b : a; }
};
template <> struct minimum<void> {
  static constexpr int red_kind = 2;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return b < a ? b : a; }
};
template <class T = void> struct maximum {
  static constexpr int red_kind = 3;
  T operator()(const T &a, const T &b) const { return a < b ? b : a; }
};
template <> struct maximum<void> {
  static constexpr int red_kind = 3;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a < b ? b : a; }
};
template <class T = void> struct bit_and {
  static constexpr int red_kind = 4;
  T operator()(const T &a, const T &b) const { return a & b; }
};
template <> struct bit_and<void> {
  static constexpr int red_kind = 4;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a & b; }
};
template <class T = void> struct bit_or {
  static constexpr int red_kind = 5;
  T operator()(const T &a, const T &b) const { return a | b; }
};
template <> struct bit_or<void> {
  static constexpr int red_kind = 5;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a | b; }
};
template <class T = void> struct bit_xor {
  static constexpr int red_kind = 6;
  T operator()(const T &a, const T &b) const { return a ^ b; }
};
template <> struct bit_xor<void> {
  static constexpr int red_kind = 6;
  template <class A, class B> auto operator()(const A &a, const B &b) const { return a ^ b; }
};

namespace detail {

// the reduction kind of a function object: a SYCL one has red_kind; any other (a user's) is -1 and combines with a
// compare-and-swap loop
template <class Op, class = void> struct op_kind { static constexpr int value = -1; };
template <class Op> struct op_kind<Op, std::void_t<decltype(Op::red_kind)>> { static constexpr int value = Op::red_kind; };

template <int K, class T> inline T red_identity() {
  if constexpr (K < 0) return T();
  else if constexpr (K == 0 || K == 5 || K == 6) return T(0);
  else if constexpr (K == 1) return T(1);
  else if constexpr (K == 2) return std::numeric_limits<T>::has_infinity ? std::numeric_limits<T>::infinity() : std::numeric_limits<T>::max();
  else if constexpr (K == 3) return std::numeric_limits<T>::has_infinity ? -std::numeric_limits<T>::infinity() : std::numeric_limits<T>::lowest();
  else return T(~T(0));
}

// combine x into *p with the reduction operation K. On the device every work-item does it with an atomic: a native one for
// the SYCL operators, a compare-and-swap loop for multiplies and for a user's function object.
template <int K, class T, class Op> inline void red_combine(T *p, T x) {
#ifdef __NFCXX_SYCL_DEVICE__
  static_assert(sizeof(T) == 4, "WebGPU reductions need a 32-bit element type");
  constexpr bool is_float = (T)0.5 != (T)0;
  constexpr bool is_signed = (T)-1 < (T)0;
  if constexpr (K < 0 || K == 1) {
    int old = __nfcxx_sycl_atomic_load((void *)p);
    while (true) {
      T cur;
      __builtin_memcpy(&cur, &old, 4);
      T nv = (T)Op()(cur, x);
      int nb;
      __builtin_memcpy(&nb, &nv, 4);
      int r = __nfcxx_sycl_atomic_cas((void *)p, old, nb);
      if (r == old) break;
      old = r;
    }
  } else if constexpr (K == 0) {
    if constexpr (is_float) __nfcxx_sycl_atomic_fadd((void *)p, (float)x);
    else __nfcxx_sycl_atomic_add((void *)p, (int)x);
  } else if constexpr (K == 2) {
    if constexpr (is_float) __nfcxx_sycl_atomic_fmin((void *)p, (float)x);
    else if constexpr (is_signed) __nfcxx_sycl_atomic_min((void *)p, (int)x);
    else __nfcxx_sycl_atomic_umin((void *)p, (int)x);
  } else if constexpr (K == 3) {
    if constexpr (is_float) __nfcxx_sycl_atomic_fmax((void *)p, (float)x);
    else if constexpr (is_signed) __nfcxx_sycl_atomic_max((void *)p, (int)x);
    else __nfcxx_sycl_atomic_umax((void *)p, (int)x);
  } else if constexpr (K == 4) {
    __nfcxx_sycl_atomic_and((void *)p, (int)x);
  } else if constexpr (K == 5) {
    __nfcxx_sycl_atomic_or((void *)p, (int)x);
  } else if constexpr (K == 6) {
    __nfcxx_sycl_atomic_xor((void *)p, (int)x);
  }
#else
  *p = (T)Op()(*p, x);   // the work-items run one at a time here
#endif
}

template <class T, class Op> struct reducer {
  T *var;
  explicit reducer(T *v) : var(v) {}
  void combine(const T &x) const { red_combine<op_kind<Op>::value, T, Op>(var, x); }
  const reducer &operator+=(const T &x) const { combine(x); return *this; }
  const reducer &operator*=(const T &x) const { combine(x); return *this; }
  const reducer &operator|=(const T &x) const { combine(x); return *this; }
  const reducer &operator&=(const T &x) const { combine(x); return *this; }
  const reducer &operator^=(const T &x) const { combine(x); return *this; }
  const reducer &operator++() const { combine(T(1)); return *this; }
};

// the kernel the library runs for parallel_for(range, reduction, f): f(item, reducer) with the reducer on the variable
template <int D, class F, class T, class Op> struct reduce_range_kernel {
  F f;
  T *var;
  void operator()(const item<D> &it) const {
    reducer<T, Op> r(var);
    f(it, r);
  }
};
template <int D, class F, class T, class Op> struct reduce_nd_kernel {
  F f;
  T *var;
  void operator()(const nd_item<D> &it) const {
    reducer<T, Op> r(var);
    f(it, r);
  }
};

template <int D, class F, class T1, class O1, class T2, class O2> struct reduce_range_kernel2 {
  F f;
  T1 *v1;
  T2 *v2;
  void operator()(const item<D> &it) const {
    reducer<T1, O1> a(v1);
    reducer<T2, O2> b(v2);
    f(it, a, b);
  }
};
template <int D, class F, class T1, class O1, class T2, class O2> struct reduce_nd_kernel2 {
  F f;
  T1 *v1;
  T2 *v2;
  void operator()(const nd_item<D> &it) const {
    reducer<T1, O1> a(v1);
    reducer<T2, O2> b(v2);
    f(it, a, b);
  }
};
template <int D, class F, class T1, class O1, class T2, class O2, class T3, class O3> struct reduce_range_kernel3 {
  F f;
  T1 *v1;
  T2 *v2;
  T3 *v3;
  void operator()(const item<D> &it) const {
    reducer<T1, O1> a(v1);
    reducer<T2, O2> b(v2);
    reducer<T3, O3> c(v3);
    f(it, a, b, c);
  }
};
template <int D, class F, class T1, class O1, class T2, class O2, class T3, class O3> struct reduce_nd_kernel3 {
  F f;
  T1 *v1;
  T2 *v2;
  T3 *v3;
  void operator()(const nd_item<D> &it) const {
    reducer<T1, O1> a(v1);
    reducer<T2, O2> b(v2);
    reducer<T3, O3> c(v3);
    f(it, a, b, c);
  }
};

}  // namespace detail

// What sycl::reduction(...) returns: the variable (a USM pointer or a buffer) and the operation.
template <class T, class Op> class reduction_desc {
 public:
  reduction_desc(T *usm, Op, bool init, T identity) : var_(usm), st_(nullptr), init_(init), id_(identity) {}
  reduction_desc(T *host, detail::buffer_state *st, unsigned long dev, Op, bool init, T identity)
      : var_(host), st_(st), dev_(dev), init_(init), id_(identity) {}
  void prepare(handler &h) const {
    if (st_) {
      if (init_) {
        *var_ = id_;
        st_->host_valid = true;
        st_->dev_valid = false;
      }
      h.use(st_, access_mode::read_write);
    } else if (init_) {
      T id = id_;
      detail::backend_memcpy(var_, &id, sizeof(T));
    }
  }
  // the pointer the kernel combines into: the device address of a buffer on the WebGPU path, else the variable itself
  T *kernel_var() const {
#ifdef NFCXX_SYCL_GPU
    if (st_) return (T *)(unsigned long)dev_;
#endif
    return var_;
  }

 private:
  T *var_;
  detail::buffer_state *st_;
  unsigned long dev_ = 0;
  bool init_;
  T id_;
};

template <class T, class Op> reduction_desc<T, Op> reduction(T *var, Op op, const property_list &pl = property_list()) {
  return reduction_desc<T, Op>(var, op, pl.init_identity(), detail::red_identity<detail::op_kind<Op>::value, T>());
}
template <class T, class Op> reduction_desc<T, Op> reduction(T *var, const T &identity, Op op, const property_list &pl = property_list()) {
  return reduction_desc<T, Op>(var, op, pl.init_identity(), identity);
}
template <class T, int D, class Op> reduction_desc<T, Op> reduction(buffer<T, D> &b, handler &, Op op, const property_list &pl = property_list()) {
  return reduction_desc<T, Op>(b.host_data(), &b.state(), detail::backend_dev_offset(b.state()), op, pl.init_identity(),
                               detail::red_identity<detail::op_kind<Op>::value, T>());
}
template <class T, int D, class Op> reduction_desc<T, Op> reduction(buffer<T, D> &b, handler &, const T &identity, Op op, const property_list &pl = property_list()) {
  return reduction_desc<T, Op>(b.host_data(), &b.state(), detail::backend_dev_offset(b.state()), op, pl.init_identity(), identity);
}

template <class Name, int D, class T, class Op, class F>
void handler::parallel_for(range<D> r, reduction_desc<T, Op> red, F f) {
  red.prepare(*this);
  detail::reduce_range_kernel<D, F, T, Op> k{f, red.kernel_var()};
  this->template parallel_for<Name>(r, k);
}
template <class Name, int D, class T, class Op, class F>
void handler::parallel_for(nd_range<D> r, reduction_desc<T, Op> red, F f) {
  red.prepare(*this);
  detail::reduce_nd_kernel<D, F, T, Op> k{f, red.kernel_var()};
  this->template parallel_for<Name>(r, k);
}

template <class Name, int D, class T1, class O1, class T2, class O2, class F>
void handler::parallel_for(range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, F f) {
  r1.prepare(*this);
  r2.prepare(*this);
  detail::reduce_range_kernel2<D, F, T1, O1, T2, O2> k{f, r1.kernel_var(), r2.kernel_var()};
  this->template parallel_for<Name>(r, k);
}
template <class Name, int D, class T1, class O1, class T2, class O2, class F>
void handler::parallel_for(nd_range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, F f) {
  r1.prepare(*this);
  r2.prepare(*this);
  detail::reduce_nd_kernel2<D, F, T1, O1, T2, O2> k{f, r1.kernel_var(), r2.kernel_var()};
  this->template parallel_for<Name>(r, k);
}
template <class Name, int D, class T1, class O1, class T2, class O2, class T3, class O3, class F>
void handler::parallel_for(range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, reduction_desc<T3, O3> r3, F f) {
  r1.prepare(*this);
  r2.prepare(*this);
  r3.prepare(*this);
  detail::reduce_range_kernel3<D, F, T1, O1, T2, O2, T3, O3> k{f, r1.kernel_var(), r2.kernel_var(), r3.kernel_var()};
  this->template parallel_for<Name>(r, k);
}
template <class Name, int D, class T1, class O1, class T2, class O2, class T3, class O3, class F>
void handler::parallel_for(nd_range<D> r, reduction_desc<T1, O1> r1, reduction_desc<T2, O2> r2, reduction_desc<T3, O3> r3, F f) {
  r1.prepare(*this);
  r2.prepare(*this);
  r3.prepare(*this);
  detail::reduce_nd_kernel3<D, F, T1, O1, T2, O2, T3, O3> k{f, r1.kernel_var(), r2.kernel_var(), r3.kernel_var()};
  this->template parallel_for<Name>(r, k);
}

// ------------------------------------------------------------------------------------------------ work-group algorithms

// Collective operations over a group: each work-item writes its value to a scratch slot, the group meets at a barrier, and
// every work-item reads what it needs. The scratch is 256 words of work-group memory on the device, the scheduler's table
// on the host path. All work-items of the group must call them, as SYCL requires.
namespace detail {
template <int D> inline size_t group_lid() {
#ifdef __NFCXX_SYCL_DEVICE__
  id<D> l = device_lid<D>();
  range<D> r = device_local_range<D>();
  return linear<D>(l, r);
#else
  host_group *g = current_group();
  return g ? (size_t)g->cur : 0;
#endif
}
template <class T> inline T *group_scratch() {
#ifdef __NFCXX_SYCL_DEVICE__
  static_assert(sizeof(T) <= 4, "work-group algorithms on WebGPU need 32-bit (or smaller) values");
  return (T *)__nfcxx_sycl_scratch();
#else
  static unsigned long one[1];
  host_group *g = current_group();
  static_assert(sizeof(T) <= sizeof(unsigned long), "value too large");
  return (T *)(g ? g->scratch.data() : one);
#endif
}
#ifdef __NFCXX_SYCL_DEVICE__
template <class T> using slot_t = T;
#endif
template <class T, int D> inline T *scratch_slot(size_t lid) {
#ifdef __NFCXX_SYCL_DEVICE__
  return group_scratch<T>() + lid;
#else
  return (T *)((unsigned long *)group_scratch<T>() + lid);   // host slots are a word wide, whatever T is
#endif
}
}  // namespace detail

template <int D> inline bool group<D>::leader() const { return detail::group_lid<D>() == 0; }
// lane k holds the combination of lanes 0..k-1 (lane 0 the identity)
template <class T, class Op> inline T exclusive_scan_over_group(sub_group sg, T x, Op op) {
  T e = shift_group_right(sg, inclusive_scan_over_group(sg, x, op), 1);
  return sg.get_local_linear_id() == 0 ? detail::red_identity<detail::op_kind<Op>::value, T>() : e;
}
template <class T, class V, class Op> inline T exclusive_scan_over_group(sub_group sg, T x, V init, Op op) {
  return op((T)init, exclusive_scan_over_group(sg, x, op));
}

template <int D, class T, class Op> inline T reduce_over_group(group<D> g, T x, Op op) {
  size_t lid = detail::group_lid<D>(), n = g.get_local_range().size();
  *detail::scratch_slot<T, D>(lid) = x;
  group_barrier(g);
  T r = *detail::scratch_slot<T, D>(0);
  for (size_t i = 1; i < n; i++) r = op(r, *detail::scratch_slot<T, D>(i));
  group_barrier(g);
  return r;
}
template <int D, class T, class V, class Op> inline T reduce_over_group(group<D> g, T x, V init, Op op) { return op((T)init, reduce_over_group(g, x, op)); }
template <int D, class T> inline T group_broadcast(group<D> g, T x, id<D> from) {
  size_t lid = detail::group_lid<D>();
  if (lid == detail::linear<D>(from, g.get_local_range())) *detail::scratch_slot<T, D>(0) = x;
  group_barrier(g);
  T r = *detail::scratch_slot<T, D>(0);
  group_barrier(g);
  return r;
}
template <int D, class T> inline T group_broadcast(group<D> g, T x) { return group_broadcast(g, x, id<D>()); }
template <int D, class T, class Op> inline T inclusive_scan_over_group(group<D> g, T x, Op op) {
  size_t lid = detail::group_lid<D>();
  *detail::scratch_slot<T, D>(lid) = x;
  group_barrier(g);
  T r = *detail::scratch_slot<T, D>(0);
  for (size_t i = 1; i <= lid; i++) r = op(r, *detail::scratch_slot<T, D>(i));
  group_barrier(g);
  return r;
}
template <int D, class T, class V, class Op> inline T exclusive_scan_over_group(group<D> g, T x, V init, Op op) {
  size_t lid = detail::group_lid<D>();
  *detail::scratch_slot<T, D>(lid) = x;
  group_barrier(g);
  T r = (T)init;
  for (size_t i = 0; i < lid; i++) r = op(r, *detail::scratch_slot<T, D>(i));
  group_barrier(g);
  return r;
}
template <int D, class T, class Op> inline T exclusive_scan_over_group(group<D> g, T x, Op op) {
  return exclusive_scan_over_group(g, x, detail::red_identity<detail::op_kind<Op>::value, T>(), op);
}
template <int D> inline bool any_of_group(group<D> g, bool p) { return reduce_over_group(g, (int)p, maximum<int>()) != 0; }
template <int D> inline bool all_of_group(group<D> g, bool p) { return reduce_over_group(g, (int)p, minimum<int>()) != 0; }
template <int D> inline bool none_of_group(group<D> g, bool p) { return reduce_over_group(g, (int)p, maximum<int>()) == 0; }
template <int D, class Ptr, class Op> inline auto joint_reduce(group<D> g, Ptr first, Ptr last, Op op) {
  using T = typename std::remove_cv<typename std::remove_reference<decltype(*first)>::type>::type;
  size_t lid = detail::group_lid<D>(), n = g.get_local_range().size();
  T r = detail::red_identity<detail::op_kind<Op>::value, T>();
  for (Ptr p = first + lid; p < last; p += n) r = op(r, *p);
  return reduce_over_group(g, r, op);
}

// ------------------------------------------------------------------------------------------------ queue

class queue {
 public:
  queue() {}
  template <class... A> queue(const A &...) {}
  template <class S> queue(const S &, const property_list &) {}
  template <class S> queue(const S &, const async_handler &, const property_list & = property_list()) {}
  template <class S> queue(const context &, const S &, const property_list & = property_list()) {}
  template <class S> queue(const context &, const S &, const async_handler &, const property_list & = property_list()) {}
  template <class CGF> event submit(CGF &&cgf) {
    event e;
    handler h;
    e.mark_started();
    cgf(h);
    return e;
  }
  template <class CGF> event submit(const event &, CGF &&cgf) { return submit(cgf); }
  template <class CGF> event submit(const std::vector<event> &, CGF &&cgf) { return submit(cgf); }

  template <class Name = void, int D, class F> event parallel_for(range<D> r, F f) {
    handler h;
    h.template parallel_for<Name>(r, f);
    return event();
  }
  template <class Name = void, int D, class F> event parallel_for(range<D> r, const event &, F f) { return parallel_for<Name>(r, f); }
  template <class Name = void, int D, class F> event parallel_for(range<D> r, const std::vector<event> &, F f) { return parallel_for<Name>(r, f); }
  template <class Name = void, class F> event parallel_for(size_t n, F f) { return parallel_for<Name>(range<1>(n), f); }
  template <class Name = void, class F> event parallel_for(size_t n, const event &, F f) { return parallel_for<Name>(range<1>(n), f); }
  template <class Name = void, class F> event parallel_for(size_t n, std::initializer_list<event>, F f) { return parallel_for<Name>(range<1>(n), f); }
  template <class Name = void, int D, class F> event parallel_for(range<D> r, std::initializer_list<event>, F f) { return parallel_for<Name>(r, f); }
  template <class Name = void, int D, class F> event parallel_for(nd_range<D> r, F f) {
    handler h;
    h.template parallel_for<Name>(r, f);
    return event();
  }
  template <class Name = void, int D, class F> event parallel_for(nd_range<D> r, const event &, F f) { return parallel_for<Name>(r, f); }
  template <class Name = void, int D, class T, class Op, class F> event parallel_for(range<D> r, reduction_desc<T, Op> red, F f) {
    handler h;
    h.template parallel_for<Name>(r, red, f);
    return event();
  }
  template <class Name = void, int D, class T, class Op, class F> event parallel_for(nd_range<D> r, reduction_desc<T, Op> red, F f) {
    handler h;
    h.template parallel_for<Name>(r, red, f);
    return event();
  }
  template <class Name = void, class F> event single_task(F f) {
    handler h;
    h.template single_task<Name>(f);
    return event();
  }
  template <class Name = void, class F> event single_task(const event &, F f) { return single_task<Name>(f); }

  event memcpy(void *dst, const void *src, size_t n) { detail::backend_memcpy(dst, src, n); return event(); }
  event memcpy(void *dst, const void *src, size_t n, const event &) { return memcpy(dst, src, n); }
  event memcpy(void *dst, const void *src, size_t n, const std::vector<event> &) { return memcpy(dst, src, n); }
  friend bool operator==(const queue &, const queue &) { return true; }   // one in-order queue in this subset
  event memset(void *p, int v, size_t n) { detail::backend_memset(p, v, n); return event(); }
  template <class T> event fill(void *p, const T &v, size_t count) {
    handler h;
    h.fill(p, v, count);
    return event();
  }
  template <class T> event copy(const T *src, T *dst, size_t count) { return memcpy(dst, src, count * sizeof(T)); }
  event prefetch(const void *, size_t) { return event(); }
  event mem_advise(const void *, size_t, int) { return event(); }

  void wait() { detail::backend_wait(); }
  void wait_and_throw() { detail::backend_wait(); }
  void throw_asynchronous() {}
  device get_device() const { return device(); }
  context get_context() const { return context(); }
  bool is_in_order() const { return true; }
};

// ------------------------------------------------------------------------------------------------ unified shared memory

namespace usm {
enum class alloc { host, device, shared, unknown };
}

namespace detail {
inline void *usm_malloc(size_t bytes, size_t align, int kind) {
  void *p = backend_usm_alloc(bytes, (unsigned)align, kind);
  if (!p && bytes) throw exception(errc::memory_allocation, "sycl: USM allocation failed");
  return p;
}
inline int kind_of(usm::alloc k) { return k == usm::alloc::device ? 0 : (k == usm::alloc::shared ? 1 : 2); }
}  // namespace detail

template <class T> T *malloc_device(size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 0); }
template <class T> T *malloc_device(size_t count, const device &, const context &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 0); }
inline void *malloc_device(size_t bytes, const device &, const context &) { return detail::usm_malloc(bytes, 16, 0); }
template <class T> T *malloc_shared(size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 1); }
template <class T> T *malloc_shared(size_t count, const device &, const context &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 1); }
template <class T> T *malloc_host(size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 2); }
template <class T> T *malloc_host(size_t count, const context &) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), 2); }
template <class T> T *aligned_alloc_device(size_t align, size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), align, 0); }
template <class T> T *aligned_alloc_shared(size_t align, size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), align, 1); }
template <class T> T *aligned_alloc_host(size_t align, size_t count, const queue &) { return (T *)detail::usm_malloc(count * sizeof(T), align, 2); }
template <class T> T *malloc(size_t count, const queue &, usm::alloc k) { return (T *)detail::usm_malloc(count * sizeof(T), alignof(T), detail::kind_of(k)); }
inline void *malloc_device(size_t bytes, const queue &) { return detail::usm_malloc(bytes, 16, 0); }
inline void *malloc_shared(size_t bytes, const queue &) { return detail::usm_malloc(bytes, 16, 1); }
inline void *malloc_host(size_t bytes, const queue &) { return detail::usm_malloc(bytes, 16, 2); }
inline void *malloc(size_t bytes, const queue &, usm::alloc k) { return detail::usm_malloc(bytes, 16, detail::kind_of(k)); }
inline void free(void *p, const queue &) { if (p) detail::backend_usm_free(p); }
inline void free(void *p, const context &) { if (p) detail::backend_usm_free(p); }
inline usm::alloc get_pointer_type(const void *p, const context &) { return detail::backend_is_usm(p) ? usm::alloc::shared : usm::alloc::unknown; }

// ------------------------------------------------------------------------------------------------ stream (host path only)

enum class stream_manipulator { flush, endl };
inline constexpr stream_manipulator flush = stream_manipulator::flush;
inline constexpr stream_manipulator endl = stream_manipulator::endl;
// A kernel that prints runs on the host path; the device compile refuses it (the body calls the C++ library).
struct setw_t { int w; };
struct setprecision_t { int p; };
inline setw_t setw(int w) { return setw_t{w}; }
inline setprecision_t setprecision(int p) { return setprecision_t{p}; }
class stream {
 public:
  stream(size_t, size_t, handler &) {}
  const stream &operator<<(setw_t m) const { std::cout << std::setw(m.w); return *this; }
  const stream &operator<<(setprecision_t m) const { std::cout << std::setprecision(m.p); return *this; }
  template <class T> const stream &operator<<(const T &v) const { std::cout << v; return *this; }
  const stream &operator<<(stream_manipulator m) const { if (m == stream_manipulator::endl) std::cout << '\n'; return *this; }
};

// ------------------------------------------------------------------------------------------------ vec

namespace detail {
template <int N> struct vec_store { static constexpr int n = N == 3 ? 4 : N; };
}
template <class T, int N> class vec {
 public:
  using element_type = T;
  vec() { for (int i = 0; i < storage; i++) v_[i] = T(); }
  vec(T x) { for (int i = 0; i < storage; i++) v_[i] = x; }
  // N arguments, one per component (a brace list of N values works too)
  template <class... A, class = detail::enable_if_t<(sizeof...(A) == (unsigned)N && N > 1)>> vec(A... a) {
    T tmp[sizeof...(A)] = {(T)a...};
    for (int i = 0; i < storage; i++) v_[i] = i < N ? tmp[i] : T();
  }
  T &operator[](int i) { return v_[i]; }
  const T &operator[](int i) const { return v_[i]; }
  // a one-element vector is usable as its element (SYCL 2020: vec<T,1> converts to T)
  template <int M = N, class = detail::enable_if_t<(M == 1)>> operator T() const { return v_[0]; }
  static constexpr size_t size() { return N; }
  T &x() { return v_[0]; }
  T &y() { static_assert(N > 1, "y"); return v_[1]; }
  T &z() { static_assert(N > 2, "z"); return v_[2]; }
  T &w() { static_assert(N > 3, "w"); return v_[3]; }
  const T &x() const { return v_[0]; }
  const T &y() const { static_assert(N > 1, "y"); return v_[1]; }
  const T &z() const { static_assert(N > 2, "z"); return v_[2]; }
  const T &w() const { static_assert(N > 3, "w"); return v_[3]; }
  template <class U> vec<U, N> convert() const {
    vec<U, N> r;
    for (int i = 0; i < N; i++) r[i] = (U)v_[i];
    return r;
  }
  // as<U>(): the same bytes read as another vector or scalar type.
  template <class U> U as() const { U u; std::memcpy(&u, v_, sizeof(U)); return u; }
  // convert<U, rounding_mode>(): the rounding is the conversion's own (round to nearest), so the mode is accepted and ignored.
  template <class U, rounding_mode> vec<U, N> convert() const { return convert<U>(); }
  friend vec operator+(const vec &a, const vec &b) { vec r; for (int i = 0; i < N; i++) r.v_[i] = a.v_[i] + b.v_[i]; return r; }
  friend vec operator-(const vec &a, const vec &b) { vec r; for (int i = 0; i < N; i++) r.v_[i] = a.v_[i] - b.v_[i]; return r; }
  friend vec operator*(const vec &a, const vec &b) { vec r; for (int i = 0; i < N; i++) r.v_[i] = a.v_[i] * b.v_[i]; return r; }
  friend vec operator/(const vec &a, const vec &b) { vec r; for (int i = 0; i < N; i++) r.v_[i] = a.v_[i] / b.v_[i]; return r; }
  friend vec operator*(const vec &a, T k) { return a * vec(k); }
  friend vec operator*(T k, const vec &a) { return vec(k) * a; }
  friend vec operator+(const vec &a, T k) { return a + vec(k); }
  friend vec operator-(const vec &a, T k) { return a - vec(k); }
  friend vec operator/(const vec &a, T k) { return a / vec(k); }
  vec operator-() const { vec r; for (int i = 0; i < N; i++) r.v_[i] = -v_[i]; return r; }
  vec &operator+=(const vec &b) { for (int i = 0; i < N; i++) v_[i] += b.v_[i]; return *this; }
  vec &operator-=(const vec &b) { for (int i = 0; i < N; i++) v_[i] -= b.v_[i]; return *this; }
  vec &operator*=(const vec &b) { for (int i = 0; i < N; i++) v_[i] *= b.v_[i]; return *this; }
  vec &operator/=(const vec &b) { for (int i = 0; i < N; i++) v_[i] /= b.v_[i]; return *this; }
  // SYCL 2020: a relational operator on vectors compares lane by lane and returns a vector of the signed integer type of
  // the same width, -1 for a true lane and 0 for a false one (dpct's vectorized_binary relies on this shape).
  using mask_elem = typename std::conditional<sizeof(T) == 1, int8_t,
                    typename std::conditional<sizeof(T) == 2, int16_t,
                    typename std::conditional<sizeof(T) == 4, int32_t, int64_t>::type>::type>::type;
  friend vec<mask_elem, N> operator==(const vec &a, const vec &b) {
    vec<mask_elem, N> r;
    for (int i = 0; i < N; i++) r[i] = (a.v_[i] == b.v_[i]) ? (mask_elem)-1 : (mask_elem)0;
    return r;
  }
  friend vec<mask_elem, N> operator!=(const vec &a, const vec &b) {
    vec<mask_elem, N> r;
    for (int i = 0; i < N; i++) r[i] = (a.v_[i] != b.v_[i]) ? (mask_elem)-1 : (mask_elem)0;
    return r;
  }

 private:
  static constexpr int storage = detail::vec_store<N>::n;
  T v_[storage];
};
template <class T, int N> inline T dot(const vec<T, N> &a, const vec<T, N> &b) { T s = T(); for (int i = 0; i < N; i++) s += a[i] * b[i]; return s; }
template <class T> inline vec<T, 3> cross(const vec<T, 3> &a, const vec<T, 3> &b) {
  return vec<T, 3>(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]);
}
using char2 = vec<signed char, 2>;   using char3 = vec<signed char, 3>;   using char4 = vec<signed char, 4>;
using uchar2 = vec<unsigned char, 2>; using uchar3 = vec<unsigned char, 3>; using uchar4 = vec<unsigned char, 4>;
using short2 = vec<short, 2>;        using short3 = vec<short, 3>;        using short4 = vec<short, 4>;
using ushort2 = vec<unsigned short, 2>; using ushort3 = vec<unsigned short, 3>; using ushort4 = vec<unsigned short, 4>;
using int2 = vec<int, 2>;            using int3 = vec<int, 3>;            using int4 = vec<int, 4>;
using uint2 = vec<unsigned, 2>;      using uint3 = vec<unsigned, 3>;      using uint4 = vec<unsigned, 4>;
using long2 = vec<long, 2>;          using long3 = vec<long, 3>;          using long4 = vec<long, 4>;
using ulong2 = vec<unsigned long, 2>; using ulong3 = vec<unsigned long, 3>; using ulong4 = vec<unsigned long, 4>;
using float2 = vec<float, 2>;        using float3 = vec<float, 3>;        using float4 = vec<float, 4>;
using double2 = vec<double, 2>;      using double3 = vec<double, 3>;      using double4 = vec<double, 4>;

// ------------------------------------------------------------------------------------------------ math

// Float math maps to WGSL builtins on the device (the op numbers are SYCL_MATH in scripts/pathb-wgsl-emit.rb) and to the
// C library on the host.
namespace detail {
enum math_op {
  M_SQRT = 1, M_EXP, M_LOG, M_SIN, M_COS, M_TAN, M_FABS, M_FLOOR, M_CEIL, M_TRUNC, M_ROUND, M_RSQRT, M_EXP2, M_LOG2,
  M_ASIN, M_ACOS, M_ATAN, M_SINH, M_COSH, M_TANH,
  M_ERF = 21, M_EXPM1, M_LOG1P,
  M_POW = 32, M_FMIN, M_FMAX, M_ATAN2, M_FMOD, M_COPYSIGN,
  M_FMA = 48, M_CLAMP, M_MIX
};
#ifndef __NFCXX_SYCL_DEVICE__
inline float fn1(int op, float x) {
  switch (op) {
    case M_SQRT: return ::sqrtf(x);
    case M_EXP: return ::expf(x);
    case M_LOG: return ::logf(x);
    case M_SIN: return ::sinf(x);
    case M_COS: return ::cosf(x);
    case M_TAN: return ::tanf(x);
    case M_FABS: return ::fabsf(x);
    case M_FLOOR: return ::floorf(x);
    case M_CEIL: return ::ceilf(x);
    case M_TRUNC: return ::truncf(x);
    case M_ROUND: return ::roundf(x);
    case M_RSQRT: return 1.0f / ::sqrtf(x);
    case M_EXP2: return ::exp2f(x);
    case M_LOG2: return ::log2f(x);
    case M_ASIN: return ::asinf(x);
    case M_ACOS: return ::acosf(x);
    case M_ATAN: return ::atanf(x);
    case M_SINH: return ::sinhf(x);
    case M_COSH: return ::coshf(x);
    case M_TANH: return ::tanhf(x);
    case M_ERF: return ::erff(x);
    case M_EXPM1: return ::expm1f(x);
    case M_LOG1P: return ::log1pf(x);
  }
  return 0.0f;
}
inline float fn2(int op, float x, float y) {
  switch (op) {
    case M_POW: return ::powf(x, y);
    case M_FMIN: return x < y ? x : y;
    case M_FMAX: return x > y ? x : y;
    case M_ATAN2: return ::atan2f(x, y);
    case M_FMOD: return ::fmodf(x, y);
    case M_COPYSIGN: return ::copysignf(x, y);
  }
  return 0.0f;
}
inline float fn3(int op, float x, float y, float z) {
  switch (op) {
    case M_FMA: return x * y + z;
    case M_CLAMP: return x < y ? y : (x > z ? z : x);
    case M_MIX: return x + (y - x) * z;
  }
  return 0.0f;
}
#endif
}  // namespace detail

#ifdef __NFCXX_SYCL_DEVICE__
#define NFCXX_SYCL_FN1(op, x) __nfcxx_sycl_fn1(op, x)
#define NFCXX_SYCL_FN2(op, x, y) __nfcxx_sycl_fn2(op, x, y)
#define NFCXX_SYCL_FN3(op, x, y, z) __nfcxx_sycl_fn3(op, x, y, z)
#else
#define NFCXX_SYCL_FN1(op, x) detail::fn1(op, x)
#define NFCXX_SYCL_FN2(op, x, y) detail::fn2(op, x, y)
#define NFCXX_SYCL_FN3(op, x, y, z) detail::fn3(op, x, y, z)
#endif

namespace detail {
template <class T> struct fp { using type = double; };
template <> struct fp<float> { using type = float; };
template <class T, class U> struct fp2 { using type = double; };
template <> struct fp2<float, float> { using type = float; };
template <class T> using enable_arith = enable_if_t<std::is_arithmetic<T>::value, int>;
}  // namespace detail
// The functions are templates: with `using namespace sycl` an unqualified sqrt(1.0f) is then the C++ library's own overload
// (the device compile lowers those to WGSL as well) and not an ambiguity. float runs as WGSL builtin, double on the host only.
#define NFCXX_SYCL_MATH1(name, M, dfn)                                                                             \
  namespace detail {                                                                                              \
  inline float m_##name(float x) { return NFCXX_SYCL_FN1(detail::M, x); }                                         \
  inline double m_##name(double x) { return dfn(x); }                                                             \
  }                                                                                                               \
  template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type name(T x) {                 \
    return detail::m_##name((typename detail::fp<T>::type)x);                                                     \
  }
#define NFCXX_SYCL_MATH2(name, M, dfn)                                                                             \
  namespace detail {                                                                                              \
  inline float m_##name(float x, float y) { return NFCXX_SYCL_FN2(detail::M, x, y); }                             \
  inline double m_##name(double x, double y) { return dfn(x, y); }                                                \
  }                                                                                                               \
  template <class T, class U, detail::enable_arith<T> = 0, detail::enable_arith<U> = 0>                           \
  inline typename detail::fp2<T, U>::type name(T x, U y) {                                                        \
    return detail::m_##name((typename detail::fp2<T, U>::type)x, (typename detail::fp2<T, U>::type)y);           \
  }
NFCXX_SYCL_MATH1(sqrt, M_SQRT, ::sqrt)
NFCXX_SYCL_MATH1(exp, M_EXP, ::exp)
NFCXX_SYCL_MATH1(log, M_LOG, ::log)
NFCXX_SYCL_MATH1(sin, M_SIN, ::sin)
NFCXX_SYCL_MATH1(cos, M_COS, ::cos)
NFCXX_SYCL_MATH1(tan, M_TAN, ::tan)
NFCXX_SYCL_MATH1(fabs, M_FABS, ::fabs)
NFCXX_SYCL_MATH1(floor, M_FLOOR, ::floor)
NFCXX_SYCL_MATH1(ceil, M_CEIL, ::ceil)
NFCXX_SYCL_MATH1(trunc, M_TRUNC, ::trunc)
NFCXX_SYCL_MATH1(round, M_ROUND, ::round)
NFCXX_SYCL_MATH1(exp2, M_EXP2, ::exp2)
NFCXX_SYCL_MATH1(log2, M_LOG2, ::log2)
NFCXX_SYCL_MATH1(asin, M_ASIN, ::asin)
NFCXX_SYCL_MATH1(acos, M_ACOS, ::acos)
NFCXX_SYCL_MATH1(atan, M_ATAN, ::atan)
NFCXX_SYCL_MATH1(sinh, M_SINH, ::sinh)
NFCXX_SYCL_MATH1(cosh, M_COSH, ::cosh)
NFCXX_SYCL_MATH1(tanh, M_TANH, ::tanh)
NFCXX_SYCL_MATH2(pow, M_POW, ::pow)
NFCXX_SYCL_MATH2(fmod, M_FMOD, ::fmod)
NFCXX_SYCL_MATH2(atan2, M_ATAN2, ::atan2)
NFCXX_SYCL_MATH2(copysign, M_COPYSIGN, ::copysign)
namespace detail {
inline float m_rsqrt(float x) { return NFCXX_SYCL_FN1(detail::M_RSQRT, x); }
inline double m_rsqrt(double x) { return 1.0 / ::sqrt(x); }
inline float m_fmin(float x, float y) { return NFCXX_SYCL_FN2(detail::M_FMIN, x, y); }
inline double m_fmin(double x, double y) { return x < y ? x : y; }
inline float m_fmax(float x, float y) { return NFCXX_SYCL_FN2(detail::M_FMAX, x, y); }
inline double m_fmax(double x, double y) { return x > y ? x : y; }
inline float m_fma(float a, float b, float c) { return NFCXX_SYCL_FN3(detail::M_FMA, a, b, c); }
inline double m_fma(double a, double b, double c) { return a * b + c; }
inline float m_clamp(float x, float lo, float hi) { return NFCXX_SYCL_FN3(detail::M_CLAMP, x, lo, hi); }
inline float m_mix(float a, float b, float t) { return NFCXX_SYCL_FN3(detail::M_MIX, a, b, t); }
inline double m_mix(double a, double b, double t) { return a + (b - a) * t; }
}  // namespace detail
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type rsqrt(T x) { return detail::m_rsqrt((typename detail::fp<T>::type)x); }
template <class T, class U, detail::enable_arith<T> = 0, detail::enable_arith<U> = 0>
inline typename detail::fp2<T, U>::type fmin(T x, U y) { return detail::m_fmin((typename detail::fp2<T, U>::type)x, (typename detail::fp2<T, U>::type)y); }
template <class T, class U, detail::enable_arith<T> = 0, detail::enable_arith<U> = 0>
inline typename detail::fp2<T, U>::type fmax(T x, U y) { return detail::m_fmax((typename detail::fp2<T, U>::type)x, (typename detail::fp2<T, U>::type)y); }
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type fma(T a, T b, T c) { return detail::m_fma((typename detail::fp<T>::type)a, (typename detail::fp<T>::type)b, (typename detail::fp<T>::type)c); }
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type mix(T a, T b, T t) { return detail::m_mix((typename detail::fp<T>::type)a, (typename detail::fp<T>::type)b, (typename detail::fp<T>::type)t); }
template <class T> inline T min(T a, T b) { return b < a ? b : a; }
template <class T> inline T max(T a, T b) { return a < b ? b : a; }
template <class T> inline T clamp(T x, T lo, T hi) { return x < lo ? lo : (hi < x ? hi : x); }
inline float clamp(float x, float lo, float hi) { return detail::m_clamp(x, lo, hi); }
inline float abs(float x) { return NFCXX_SYCL_FN1(detail::M_FABS, x); }
inline int abs(int x) { return x < 0 ? -x : x; }

// classification of a binary32 value by arithmetic alone (no library call for the device to lower): x - x is 0 for a finite
// x and NaN for an infinity. isnan is in lib/sycl-ggml/sycl/half_type.hpp.
inline bool isinf(float x) { return x == x && (x - x) != 0.0f; }
inline bool isfinite(float x) { return (x - x) == 0.0f; }

// add_sat and sub_sat (SYCL 2020 integer saturating arithmetic): the result clamped to the range of T. dpct's sub_sat functor
// (dpct/helper.hpp) calls sycl::sub_sat on the lanes of a vectorized binary op, so every integer type reaches here.
template <class T, class = detail::enable_if_t<std::is_integral<T>::value && !std::is_same<T, bool>::value>>
inline T sub_sat(T x, T y) {
  if constexpr (std::is_unsigned<T>::value) {
    return x > y ? (T)(x - y) : (T)0;
  } else {
    if (y > 0 && x < std::numeric_limits<T>::min() + y) return std::numeric_limits<T>::min();
    if (y < 0 && x > std::numeric_limits<T>::max() + y) return std::numeric_limits<T>::max();
    return (T)(x - y);
  }
}
// on vectors: lane by lane (dpct's vectorized_binary passes sycl::char4 and friends)
template <class T, int N, class = detail::enable_if_t<std::is_integral<T>::value && !std::is_same<T, bool>::value>>
inline vec<T, N> sub_sat(const vec<T, N> &x, const vec<T, N> &y) {
  vec<T, N> r;
  for (int i = 0; i < N; i++) r[i] = sub_sat(x[i], y[i]);
  return r;
}
template <class T, class = detail::enable_if_t<std::is_integral<T>::value && !std::is_same<T, bool>::value>>
inline T add_sat(T x, T y) {
  if constexpr (std::is_unsigned<T>::value) {
    return (T)(x + y) < x ? std::numeric_limits<T>::max() : (T)(x + y);
  } else {
    if (y > 0 && x > std::numeric_limits<T>::max() - y) return std::numeric_limits<T>::max();
    if (y < 0 && x < std::numeric_limits<T>::min() - y) return std::numeric_limits<T>::min();
    return (T)(x + y);
  }
}
template <class T, int N, class = detail::enable_if_t<std::is_integral<T>::value && !std::is_same<T, bool>::value>>
inline vec<T, N> add_sat(const vec<T, N> &x, const vec<T, N> &y) {
  vec<T, N> r;
  for (int i = 0; i < N; i++) r[i] = add_sat(x[i], y[i]);
  return r;
}

// erf, expm1 and log1p (ggml's element_wise.cpp names them in op_erf, op_expm1, op_log1p). float runs as the device
// builtins M_ERF, M_EXPM1, M_LOG1P (OpenCL.std erf, expm1, log1p; the SPIR-V emitter lowers them). double runs as the same
// builtins on the double form __nfcxx_sycl_fn1_f64 (OpenCL.std on Float64). On the host these are the C library's.
||||||| parent of dda6fb6cf2 (sycl shim: fattn-vec front-end gaps, regression cases, fattn harness)
// erf, expm1 and log1p (ggml's element_wise.cpp names them in op_erf, op_expm1, op_log1p). They are not among the device math
// ops (detail::math_op), and the device emitter has no lowering for them. On the host they are the C library's; on the device
// a kernel that reaches one traps (it does not compute a wrong value). Templates, so only an instantiated call is emitted.
namespace detail {
#ifdef __NFCXX_SYCL_DEVICE__
inline float m_erf(float x) { return NFCXX_SYCL_FN1(detail::M_ERF, x); }
inline float m_expm1(float x) { return NFCXX_SYCL_FN1(detail::M_EXPM1, x); }
inline float m_log1p(float x) { return NFCXX_SYCL_FN1(detail::M_LOG1P, x); }
inline double m_erf(double x) { return __nfcxx_sycl_fn1_f64(detail::M_ERF, x); }
inline double m_expm1(double x) { return __nfcxx_sycl_fn1_f64(detail::M_EXPM1, x); }
inline double m_log1p(double x) { return __nfcxx_sycl_fn1_f64(detail::M_LOG1P, x); }
#else
inline float m_erf(float x) { return ::erff(x); }
inline float m_expm1(float x) { return ::expm1f(x); }
inline float m_log1p(float x) { return ::log1pf(x); }
inline double m_erf(double x) { return ::erf(x); }
inline double m_expm1(double x) { return ::expm1(x); }
inline double m_log1p(double x) { return ::log1p(x); }
#endif
}  // namespace detail
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type erf(T x) { return detail::m_erf((typename detail::fp<T>::type)x); }
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type expm1(T x) { return detail::m_expm1((typename detail::fp<T>::type)x); }
template <class T, detail::enable_arith<T> = 0> inline typename detail::fp<T>::type log1p(T x) { return detail::m_log1p((typename detail::fp<T>::type)x); }

// sycl::native::exp (the fast-math exp; the compat library has one exp, so it is that one).
namespace native {
inline float exp(float x) { return sycl::exp(x); }
}  // namespace native

// sycl::ext::oneapi: the names element_wise.cpp spells out for its bfloat16 and work-item branches. bfloat16 is the bf16
// storage (the upper 16 bits of a binary32, round-to-nearest-even on conversion from float); arithmetic and math go
// through float and round the result back to bf16, as the device's bf16 math does.
namespace ext {
namespace oneapi {
class bfloat16 {
 public:
  bfloat16() = default;
  bfloat16(float f) : bits_(from_float(f)) {}
  operator float() const { return to_float(bits_); }
  uint16_t bits() const { return bits_; }
  static bfloat16 from_bits(uint16_t b) { bfloat16 r; r.bits_ = b; return r; }

 private:
  uint16_t bits_ = 0;

  static float to_float(uint16_t b) {
    uint32_t u = (uint32_t)b << 16;
    float f;
    std::memcpy(&f, &u, 4);
    return f;
  }
  static uint16_t from_float(float f) {
    uint32_t u;
    std::memcpy(&u, &f, 4);
    if ((u & 0x7fffffffu) > 0x7f800000u) return 0x7fc0;  // NaN stays NaN
    u += 0x7fffu + ((u >> 16) & 1u);                      // round to nearest even
    return (uint16_t)(u >> 16);
  }
};
inline bfloat16 operator-(bfloat16 a) { return bfloat16(-static_cast<float>(a)); }
inline bfloat16 operator+(bfloat16 a, bfloat16 b) { return bfloat16(static_cast<float>(a) + static_cast<float>(b)); }
inline bfloat16 operator-(bfloat16 a, bfloat16 b) { return bfloat16(static_cast<float>(a) - static_cast<float>(b)); }
inline bfloat16 operator*(bfloat16 a, bfloat16 b) { return bfloat16(static_cast<float>(a) * static_cast<float>(b)); }
inline bfloat16 operator/(bfloat16 a, bfloat16 b) { return bfloat16(static_cast<float>(a) / static_cast<float>(b)); }
namespace experimental {
// The device architectures ggml-sycl names (gpu_arch in sycl_hw.hpp). The values are the ones the oneAPI runtime reports
// (device_architecture.def), so an architecture read from the runtime compares equal to these. Only the Intel GPUs that the
// backend mentions are listed.
enum class architecture : uint64_t {
  intel_gpu_bdw = 0x0000000200000000, intel_gpu_skl = 0x0000000240000900, intel_gpu_kbl = 0x0000000240400900,
  intel_gpu_cfl = 0x0000000240800900, intel_gpu_apl = 0x0000000240c00000, intel_gpu_glk = 0x0000000241000000,
  intel_gpu_whl = 0x0000000241400000, intel_gpu_aml = 0x0000000241800000, intel_gpu_cml = 0x0000000241c00000,
  intel_gpu_icllp = 0x00000002c0000000, intel_gpu_ehl = 0x00000002c0800000, intel_gpu_tgllp = 0x0000000300000000,
  intel_gpu_rkl = 0x0000000300400000, intel_gpu_adl_s = 0x0000000300800000, intel_gpu_adl_p = 0x0000000300c00000,
  intel_gpu_adl_n = 0x0000000301000000, intel_gpu_dg1 = 0x0000000302800000, intel_gpu_acm_g10 = 0x000000030dc00800,
  intel_gpu_acm_g11 = 0x000000030e000500, intel_gpu_acm_g12 = 0x000000030e400000, intel_gpu_pvc = 0x000000030f000700,
  intel_gpu_pvc_vg = 0x000000030f400700, intel_gpu_mtl_u = 0x0000000311800400, intel_gpu_mtl_h = 0x0000000311c00400,
  intel_gpu_arl_h = 0x0000000312800400, intel_gpu_bmg_g21 = 0x0000000500400400, intel_gpu_bmg_g31 = 0x0000000500800000,
  intel_gpu_lnl_m = 0x0000000501000400, intel_gpu_ptl_h = 0x0000000780000400, intel_gpu_ptl_u = 0x0000000780400100,
  intel_gpu_wcl = 0x0000000780c00000,
  // aliases of the entries above (device_architecture.def)
  intel_gpu_dg2_g10 = intel_gpu_acm_g10, intel_gpu_dg2_g11 = intel_gpu_acm_g11, intel_gpu_dg2_g12 = intel_gpu_acm_g12,
  intel_gpu_icl = intel_gpu_icllp, intel_gpu_tgl = intel_gpu_tgllp, intel_gpu_bxt = intel_gpu_apl,
};

// The bf16 math of the ops' bfloat16 arms: the float function of the rounded input, rounded back to bf16.
#define NFCXX_SYCL_BF16_FN1(name) \
  inline bfloat16 name(bfloat16 x) { return bfloat16(::sycl::name(static_cast<float>(x))); }
#define NFCXX_SYCL_BF16_FN2(name) \
  inline bfloat16 name(bfloat16 x, bfloat16 y) { return bfloat16(::sycl::name(static_cast<float>(x), static_cast<float>(y))); }
NFCXX_SYCL_BF16_FN1(fabs) NFCXX_SYCL_BF16_FN1(exp) NFCXX_SYCL_BF16_FN1(exp2) NFCXX_SYCL_BF16_FN1(expm1)
NFCXX_SYCL_BF16_FN1(log) NFCXX_SYCL_BF16_FN1(log2) NFCXX_SYCL_BF16_FN1(log1p) NFCXX_SYCL_BF16_FN1(sqrt)
NFCXX_SYCL_BF16_FN1(sin) NFCXX_SYCL_BF16_FN1(cos) NFCXX_SYCL_BF16_FN1(tan) NFCXX_SYCL_BF16_FN1(tanh)
NFCXX_SYCL_BF16_FN1(erf) NFCXX_SYCL_BF16_FN1(floor) NFCXX_SYCL_BF16_FN1(ceil) NFCXX_SYCL_BF16_FN1(trunc)
NFCXX_SYCL_BF16_FN1(round)
NFCXX_SYCL_BF16_FN2(fmax) NFCXX_SYCL_BF16_FN2(fmin)
#undef NFCXX_SYCL_BF16_FN1
#undef NFCXX_SYCL_BF16_FN2
}  // namespace experimental
}  // namespace oneapi
}  // namespace ext

}  // namespace sycl

#endif
