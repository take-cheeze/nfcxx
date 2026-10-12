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

// The device built-ins, for the host compile of a kernel body. The host copy of a kernel is never run (a launch
// goes to the runtime), so these placeholders only have to exist and link.
inline const uint3 threadIdx{0, 0, 0};
inline const uint3 blockIdx{0, 0, 0};
inline const dim3 blockDim{1, 1, 1};
inline const dim3 gridDim{1, 1, 1};

// The block barrier, for the host copy of a kernel body (never run; the device code has the real barrier).
inline void __syncthreads(void) {}

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

#endif  // NFCXX_CUDA_H
