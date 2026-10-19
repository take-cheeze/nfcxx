// Runtime side of the CUDA launch rewrite (scripts/cuda-rewrite.rb). The nfcxx driver includes this header before
// every .cu input. A launch `k<<<grid, block, shmem, stream>>>(args)` is a call of __nfcxx_cuda_launch, which packs
// the arguments into the kernel's parameter types and launches the kernel's device code. Link with -lcudart.
//
// The device code of a .cu file is built by the driver (scripts/cuda-rewrite.rb --device, scripts/pathb-ptx-emit.rb,
// ptxas) and appended to the host copy as a registration tail (scripts/cuda-embed.rb): a static object whose
// constructor loads the image with cudaLibraryLoadData and maps each kernel's host address to its cudaKernel_t.
// The qualifiers are empty: a kernel is an ordinary function on the host side. Kernels must return void.
#ifndef NFCXX_CUDA_H
#define NFCXX_CUDA_H

#include <cuda_runtime.h>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <tuple>
#include <utility>
#include <vector>

#undef __global__
#undef __device__
#undef __host__
#undef __shared__
#undef __constant__
#undef __managed__
#define __global__
#define __device__
#define __host__
#define __shared__
#define __constant__
#define __managed__
// The host copy of a kernel: __launch_bounds__ is a hint for the device compile. cuda_runtime.h defines it only when
// __CUDACC__ is set, which the host compile is not, so a header kernel (one the rewrite does not touch) would keep the
// call and break the parse. An empty default covers headers too.
#ifndef __launch_bounds__
#define __launch_bounds__(...)
#endif

// The device built-ins, for the host compile of a kernel body. The host copy of a kernel is never run (a launch
// goes to the runtime), so these placeholders only have to exist and link.
inline const uint3 threadIdx{0, 0, 0};
inline const uint3 blockIdx{0, 0, 0};
inline const dim3 blockDim{1, 1, 1};
inline const dim3 gridDim{1, 1, 1};

// The block barrier, for the host copy of a kernel body (never run; the device code has the real barrier).
inline void __syncthreads(void) {}
// The warp barrier, likewise (CUDA: __syncwarp(mask) with the full mask by default).
inline void __syncwarp(unsigned int mask = 0xffffffffu) { (void)mask; }
// The optimizer hint __builtin_assume(x): the host compiler has none; the hint does not change the result.
#ifndef __builtin_assume
#define __builtin_assume(x) ((void)0)
#endif
// Scalar helpers, for the host copy (never run).
inline unsigned int __float_as_uint(float f) { unsigned int u; __builtin_memcpy(&u, &f, sizeof u); return u; }
inline int __float2int_rn(float f) { return (int)f; }
inline float __frcp_rn(float x) { return 1.0f / x; }
inline unsigned long __cvta_generic_to_shared(const void *p) { (void)p; return 0; }
inline unsigned int __hgt2_mask(unsigned int a, unsigned int b) { (void)a; (void)b; return 0u; }
// The trap and the warp votes, for the host copy (never run).
inline void __trap(void) {}
inline unsigned int __ballot_sync(unsigned int mask, int pred) { (void)mask; (void)pred; return 0u; }
inline int __any_sync(unsigned int mask, int pred) { (void)mask; (void)pred; return 0; }
inline int __all_sync(unsigned int mask, int pred) { (void)mask; (void)pred; return 0; }
// The CUDA math overloads of min and max (unqualified calls in device code; the host copy never runs them).
inline int min(int a, int b) { return a < b ? a : b; }
inline unsigned int min(unsigned int a, unsigned int b) { return a < b ? a : b; }
inline long min(long a, long b) { return a < b ? a : b; }
inline unsigned long min(unsigned long a, unsigned long b) { return a < b ? a : b; }
inline long long min(long long a, long long b) { return a < b ? a : b; }
inline unsigned long long min(unsigned long long a, unsigned long long b) { return a < b ? a : b; }
inline float min(float a, float b) { return a < b ? a : b; }
inline double min(double a, double b) { return a < b ? a : b; }
inline int max(int a, int b) { return a > b ? a : b; }
inline unsigned int max(unsigned int a, unsigned int b) { return a > b ? a : b; }
inline long max(long a, long b) { return a > b ? a : b; }
inline unsigned long max(unsigned long a, unsigned long b) { return a > b ? a : b; }
inline long long max(long long a, long long b) { return a > b ? a : b; }
inline unsigned long long max(unsigned long long a, unsigned long long b) { return a > b ? a : b; }
inline float max(float a, float b) { return a > b ? a : b; }
inline double max(double a, double b) { return a > b ? a : b; }

// Device intrinsics, for the host copy of a kernel body (never run; the device code has the real instruction).
// Signatures follow CUDA's; the values are placeholders.
inline float __fdividef(float a, float b) { return a / b; }
inline float __saturatef(float a) { return a < 0.0f ? 0.0f : (a > 1.0f ? 1.0f : a); }
inline float __ldg(const float *p) { return *p; }
inline int __ldg(const int *p) { return *p; }
inline unsigned int __ldg(const unsigned int *p) { return *p; }
inline int __dp4a(int a, int b, int c) { (void)a; (void)b; return c; }
inline float __shfl_up_sync(unsigned int mask, float v, unsigned int delta, int width = 32) { (void)mask; (void)delta; (void)width; return v; }
inline int __shfl_up_sync(unsigned int mask, int v, unsigned int delta, int width = 32) { (void)mask; (void)delta; (void)width; return v; }
inline int __syncthreads_or(int predicate) { return predicate != 0; }
inline unsigned int __reduce_add_sync(unsigned int mask, unsigned int value) { (void)mask; return value; }
inline void __threadfence_system(void) {}
inline void __nanosleep(unsigned int ns) { (void)ns; }
// The device code is the atomic (the prelude's atomicAdd and friends); the host copy only has to name them.
inline int atomicAdd(int *p, int v) { int o = *p; *p = o + v; return o; }
inline unsigned int atomicAdd(unsigned int *p, unsigned int v) { unsigned int o = *p; *p = o + v; return o; }
inline float atomicAdd(float *p, float v) { float o = *p; *p = o + v; return o; }
inline int atomicMax(int *p, int v) { int o = *p; *p = o > v ? o : v; return o; }
inline int atomicCAS(int *p, int c, int v) { int o = *p; if (o == c) *p = v; return o; }
inline unsigned short __hmax(unsigned short a, unsigned short b) { return a > b ? a : b; }
// glibc declares these (C linkage, throw()); the inline definitions match it, so every unit may include this header.
extern "C" inline float __expf(float x) throw() { return __builtin_expf(x); }
extern "C" inline float __logf(float x) throw() { return __builtin_logf(x); }

// The integer intrinsics, for the host copy of a kernel and for host code that calls them (the device side is in the
// device unit, scripts/cuda-rewrite.rb BUILTIN_DEFS). Real C++ here, with CUDA's definitions. The shuffles on the host
// return the value of the calling lane (there is one lane on the host).
inline unsigned __umulhi(unsigned a, unsigned b) { return (unsigned)(((unsigned long long)a * b) >> 32); }
inline int __popc(unsigned x) { int n = 0; while (x) { x &= x - 1; ++n; } return n; }
inline int __popcll(unsigned long long x) { return __popc((unsigned)x) + __popc((unsigned)(x >> 32)); }
inline unsigned __byte_perm(unsigned x, unsigned y, unsigned s) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++) {
    unsigned sel = (s >> (4 * i)) & 7u;
    unsigned src = sel < 4 ? x : y;
    r |= ((src >> (8 * (sel & 3))) & 0xffu) << (8 * i);
  }
  return r;
}
inline unsigned __vsub4(unsigned a, unsigned b) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++) r |= (((a >> (8 * i)) - (b >> (8 * i))) & 0xffu) << (8 * i);
  return r;
}
inline unsigned __vcmpne4(unsigned a, unsigned b) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++)
    if (((a >> (8 * i)) & 0xffu) != ((b >> (8 * i)) & 0xffu)) r |= 0xffu << (8 * i);
  return r;
}
inline int __shfl_xor_sync(unsigned, int v, int, int = 32) { return v; }
inline float __shfl_xor_sync(unsigned, float v, int, int = 32) { return v; }
inline int __shfl_down_sync(unsigned, int v, unsigned, int = 32) { return v; }
inline float __shfl_down_sync(unsigned, float v, unsigned, int = 32) { return v; }
inline int __shfl_sync(unsigned, int v, int, int = 32) { return v; }
inline float __shfl_sync(unsigned, float v, int, int = 32) { return v; }
// The block's dynamic shared memory (`extern __shared__ T x[]`, scripts/cuda-rewrite.rb): a placeholder for the host
// copy of a kernel, which never runs. The device side lowers the call to the address of the .extern .shared symbol.
inline void *__nfcxx_dynshared_addr(void) { return nullptr; }

// One entry per kernel of a translation unit: the host function and the entry name of its device code.
struct __nfcxx_kernel_entry {
  const void *host;
  const char *entry;
};

// Host address -> cudaKernel_t, filled when a module is registered (static initialization, before main).
inline std::vector<std::pair<const void *, cudaKernel_t>> &__nfcxx_registry() {
  static std::vector<std::pair<const void *, cudaKernel_t>> registry;
  return registry;
}

inline void __nfcxx_cuda_register_module(const unsigned char *image, const __nfcxx_kernel_entry *table,
                                         std::size_t count) {
  cudaLibrary_t lib;
  if (cudaLibraryLoadData(&lib, image, nullptr, nullptr, 0, nullptr, nullptr, 0) != cudaSuccess) {
    std::fprintf(stderr, "nfcxx: cannot load the device image of this file\n");
    std::abort();
  }
  for (std::size_t i = 0; i < count; i++) {
    cudaKernel_t kernel;
    if (cudaLibraryGetKernel(&kernel, lib, table[i].entry) != cudaSuccess) {
      std::fprintf(stderr, "nfcxx: no device kernel %s in the device image\n", table[i].entry);
      std::abort();
    }
    __nfcxx_registry().push_back({table[i].host, kernel});
  }
}

struct __nfcxx_module_init {
  __nfcxx_module_init(const unsigned char *image, std::size_t size, const __nfcxx_kernel_entry *table,
                      std::size_t count) {
    (void)size;  // cudaLibraryLoadData takes the image as a whole
    __nfcxx_cuda_register_module(image, table, count);
  }
};

inline cudaKernel_t __nfcxx_find_kernel(const void *host) {
  for (const auto &e : __nfcxx_registry()) {
    if (e.first == host) return e.second;
  }
  return nullptr;
}

template <typename... P, std::size_t... I>
inline cudaError_t __nfcxx_cuda_launch_impl(cudaKernel_t kernel, dim3 grid, dim3 block, std::size_t shmem,
                                            cudaStream_t stream, std::tuple<P...> &packed,
                                            std::index_sequence<I...>) {
  // One pointer per parameter, then a null terminator: the launch reads only the parameters the kernel has.
  void *argv[sizeof...(P) + 1] = {static_cast<void *>(&std::get<I>(packed))..., nullptr};
  cudaLaunchConfig_t cfg = {};
  cfg.gridDim = grid;
  cfg.blockDim = block;
  cfg.dynamicSmemBytes = shmem;
  cfg.stream = stream;
  return cudaLaunchKernelExC(&cfg, reinterpret_cast<const void *>(kernel), argv);
}

template <typename... P, typename... A>
inline cudaError_t __nfcxx_cuda_launch(void (*kernel)(P...), dim3 grid, dim3 block, std::size_t shmem,
                                       cudaStream_t stream, A... args) {
  static_assert(sizeof...(P) == sizeof...(A), "kernel launch: wrong number of arguments");
  cudaKernel_t device = __nfcxx_find_kernel(reinterpret_cast<const void *>(kernel));
  if (device == nullptr) return cudaErrorInvalidDeviceFunction;
  std::tuple<P...> packed(static_cast<P>(args)...);
  return __nfcxx_cuda_launch_impl(device, grid, block, shmem, stream, packed, std::index_sequence_for<P...>());
}

// cudaLaunchKernelEx (the CUDA headers' template calls cudaLaunchKernelExC with the host function, which is not a
// device kernel here). The name is redirected below to this template, which looks the kernel up in the registry and
// passes the configuration through unchanged. A host function that is not registered is an error, as in the launch.
template <typename... P, std::size_t... I>
inline cudaError_t __nfcxx_launch_ex_impl(const cudaLaunchConfig_t *config, cudaKernel_t kernel,
                                          std::tuple<P...> &packed, std::index_sequence<I...>) {
  void *argv[sizeof...(P) + 1] = {static_cast<void *>(&std::get<I>(packed))..., nullptr};
  return cudaLaunchKernelExC(config, reinterpret_cast<const void *>(kernel), argv);
}

template <typename... P, typename... A>
inline cudaError_t __nfcxx_cudaLaunchKernelEx(const cudaLaunchConfig_t *config, void (*kernel)(P...), A &&...args) {
  static_assert(sizeof...(P) == sizeof...(A), "kernel launch: wrong number of arguments");
  cudaKernel_t device = __nfcxx_find_kernel(reinterpret_cast<const void *>(kernel));
  if (device == nullptr) return cudaErrorInvalidDeviceFunction;
  std::tuple<P...> packed(static_cast<P>(args)...);
  return __nfcxx_launch_ex_impl(config, device, packed, std::index_sequence_for<P...>());
}
// Calls of cudaLaunchKernelEx from here on (the CUDA template above stays, for code that includes it before this header).
#define cudaLaunchKernelEx __nfcxx_cudaLaunchKernelEx

// The runtime's host-address calls (cudaFuncSetAttribute, cudaLaunchKernel) do not know the kernels: they are
// loaded with cudaLibraryLoadData, so the host address is looked up in the registry first. The macros only rewrite
// direct calls in the source (llama.cpp calls cudaFuncSetAttribute on kernel addresses); cudaLaunchKernelEx goes
// through the CUDA headers' template and is not covered.
template <typename F>
inline cudaError_t __nfcxx_cuda_func_set_attribute(F func, cudaFuncAttribute attr, int value) {
  cudaKernel_t kernel = __nfcxx_find_kernel(reinterpret_cast<const void *>(func));
  if (kernel == nullptr) return cudaErrorInvalidDeviceFunction;
  int device = 0;
  cudaError_t err = cudaGetDevice(&device);
  if (err != cudaSuccess) return err;
  return cudaKernelSetAttributeForDevice(kernel, attr, value, device);
}

template <typename F>
inline cudaError_t __nfcxx_cuda_launch_raw(F func, dim3 grid, dim3 block, void **args, std::size_t shmem,
                                           cudaStream_t stream) {
  cudaKernel_t kernel = __nfcxx_find_kernel(reinterpret_cast<const void *>(func));
  if (kernel == nullptr) return cudaErrorInvalidDeviceFunction;
  cudaLaunchConfig_t cfg = {};
  cfg.gridDim = grid;
  cfg.blockDim = block;
  cfg.dynamicSmemBytes = shmem;
  cfg.stream = stream;
  return cudaLaunchKernelExC(&cfg, reinterpret_cast<const void *>(kernel), args);
}

#define cudaFuncSetAttribute(func, attr, value) __nfcxx_cuda_func_set_attribute((func), (attr), (value))
#define cudaLaunchKernel(func, grid, block, args, shmem, stream) \
  __nfcxx_cuda_launch_raw((func), (grid), (block), (args), (shmem), (stream))

// A cooperative launch: the driver checks that every block is resident (cudaErrorCooperativeLaunchTooLarge otherwise),
// which the grid barrier of grid_group::sync (scripts/cuda-rewrite.rb's GRID_DEF in the device unit) relies on.
template <typename F>
inline cudaError_t __nfcxx_cuda_launch_cooperative(F func, dim3 grid, dim3 block, void **args, std::size_t shmem,
                                                   cudaStream_t stream) {
  cudaKernel_t kernel = __nfcxx_find_kernel(reinterpret_cast<const void *>(func));
  if (kernel == nullptr) return cudaErrorInvalidDeviceFunction;
  cudaLaunchConfig_t cfg = {};
  cfg.gridDim = grid;
  cfg.blockDim = block;
  cfg.dynamicSmemBytes = shmem;
  cfg.stream = stream;
  cudaLaunchAttribute attr = {};
  attr.id = cudaLaunchAttributeCooperative;
  attr.val.cooperative = 1;
  cfg.attrs = &attr;
  cfg.numAttrs = 1;
  return cudaLaunchKernelExC(&cfg, reinterpret_cast<const void *>(kernel), args);
}
#define cudaLaunchCooperativeKernel(func, grid, block, args, shmem, stream) \
  __nfcxx_cuda_launch_cooperative((func), (grid), (block), (args), (shmem), (stream))

// Cooperative groups, host copy: CUDA's own cooperative_groups.h needs its device barriers, which the host placeholders do
// not provide, so the header is skipped (its guards are defined here) and this shim stands in for it. The host copy never
// runs device code: a shuffle or a reduction returns its argument, and the device unit has its own (COOP_DEF in
// scripts/cuda-rewrite.rb), which carries the lane arithmetic.
#define _COOPERATIVE_GROUPS_H_
#define _COOPERATIVE_GROUPS_REDUCE_H
namespace cooperative_groups {
typedef unsigned int thread_block;
inline thread_block this_thread_block(void) { return 0u; }
inline void sync(thread_block) {}
template <unsigned N> struct thread_block_tile {
  unsigned size(void) const { return N; }
  unsigned thread_rank(void) const { return 0u; }
  void sync(void) const {}
  template <typename T> T shfl(T v, unsigned) const { return v; }
  template <typename T> T shfl_down(T v, unsigned) const { return v; }
  template <typename T> T shfl_up(T v, unsigned) const { return v; }
  template <typename T> T shfl_xor(T v, unsigned) const { return v; }
};
template <unsigned N> thread_block_tile<N> tiled_partition(const thread_block &) { return thread_block_tile<N>(); }
struct grid_group {
  void sync(void) const {}
  unsigned thread_rank(void) const { return 0u; }
};
inline grid_group this_grid(void) { return grid_group(); }
template <typename T> struct plus { T operator()(T a, T b) const { return a + b; } };
template <typename T> struct less { T operator()(T a, T b) const { return b < a ? b : a; } };
template <typename T> struct greater { T operator()(T a, T b) const { return a < b ? b : a; } };
template <unsigned N, typename T, typename Op> T reduce(const thread_block_tile<N> &, T val, Op) { return val; }
}
namespace cg = cooperative_groups;

#endif  // NFCXX_CUDA_H
