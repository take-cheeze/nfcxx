// Runtime side of the CUDA launch rewrite (scripts/cuda-rewrite.rb). The nfcxx driver includes this header before
// every .cu input. A launch `k<<<grid, block, shmem, stream>>>(args)` is a call of __nfcxx_cuda_launch, which packs
// the arguments into the kernel's parameter types and calls cudaLaunchKernel. Link with -lcudart.
//
// The qualifiers are empty: a kernel is an ordinary function on the host side, and its device code is not compiled
// here (see docs/notes/gpu.md). Kernels must be declared with `void` return.
#ifndef NFCXX_CUDA_H
#define NFCXX_CUDA_H

#include <cuda_runtime.h>
#include <cstddef>
#include <tuple>
#include <utility>

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

template <typename... P, std::size_t... I>
inline cudaError_t __nfcxx_cuda_launch_impl(void (*kernel)(P...), dim3 grid, dim3 block, std::size_t shmem,
                                            cudaStream_t stream, std::tuple<P...> &packed,
                                            std::index_sequence<I...>) {
  // One pointer per parameter, then a null terminator: cudaLaunchKernel reads only the parameters the kernel has.
  void *argv[sizeof...(P) + 1] = {static_cast<void *>(&std::get<I>(packed))..., nullptr};
  return cudaLaunchKernel(reinterpret_cast<const void *>(kernel), grid, block, argv, shmem, stream);
}

template <typename... P, typename... A>
inline cudaError_t __nfcxx_cuda_launch(void (*kernel)(P...), dim3 grid, dim3 block, std::size_t shmem,
                                       cudaStream_t stream, A... args) {
  static_assert(sizeof...(P) == sizeof...(A), "kernel launch: wrong number of arguments");
  std::tuple<P...> packed(static_cast<P>(args)...);
  return __nfcxx_cuda_launch_impl(kernel, grid, block, shmem, stream, packed,
                                  std::index_sequence_for<P...>());
}

#endif  // NFCXX_CUDA_H
