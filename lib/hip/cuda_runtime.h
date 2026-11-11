// The CUDA runtime API on the HIP runtime, for nfcxx's AMD GPU path (NFCXX_CUDA_TARGET=amdgpu, docs/notes/gpu.md,
// "AMD GPUs (ROCm)"). A .cu file that includes <cuda_runtime.h> gets this header when lib/hip is on the include path
// first; lib/cuda/nfcxx_cuda.h then runs on HIP unchanged. A library is a HIP module (hipModuleLoadData), a kernel its
// function, and cudaLaunchKernelExC is hipModuleLaunchKernel: the kernel argument array is the same (pointers to the
// arguments, packed by the code object's metadata).
//
// Mapped to HIP: the runtime calls the programs and nfcxx_cuda.h make. Stubbed (declared, so the templates that name
// them compile, and they fail with cudaErrorNotSupported when called): the occupancy and function-attribute queries, the
// raw host-address launches, and the cooperative launch. A call that reaches a stub is reported, not silently ignored.
#ifndef NFCXX_HIP_CUDA_RUNTIME_H
#define NFCXX_HIP_CUDA_RUNTIME_H

#ifndef __HIP_PLATFORM_AMD__
#define __HIP_PLATFORM_AMD__ 1
#endif
#include <hip/hip_runtime_api.h>
#include <cstddef>

// CUDA's alignment attribute (a declaration or a type takes it before the declarator).
#define __align__(n) __attribute__((aligned(n)))

typedef hipError_t cudaError_t;
typedef hipStream_t cudaStream_t;
typedef hipModule_t cudaLibrary_t;
typedef hipFunction_t cudaKernel_t;
typedef hipFuncAttribute cudaFuncAttribute;
typedef hipFuncAttributes cudaFuncAttributes;

#define cudaSuccess hipSuccess
#define cudaErrorNotSupported hipErrorNotSupported
#define cudaErrorInvalidDeviceFunction hipErrorInvalidDeviceFunction
#define cudaErrorCooperativeLaunchTooLarge hipErrorCooperativeLaunchTooLarge
#define cudaFuncAttributeMaxDynamicSharedMemorySize hipFuncAttributeMaxDynamicSharedMemorySize

#define cudaGetErrorString hipGetErrorString
#define cudaGetLastError hipGetLastError
#define cudaPeekAtLastError hipPeekAtLastError
#define cudaDeviceSynchronize hipDeviceSynchronize
#define cudaGetDevice hipGetDevice
#define cudaMalloc hipMalloc
#define cudaMallocAsync hipMallocAsync
#define cudaFree hipFree
#define cudaFreeAsync hipFreeAsync
#define cudaMemset hipMemset
#define cudaMemsetAsync hipMemsetAsync
#define cudaMemcpy hipMemcpy
#define cudaMemcpyAsync hipMemcpyAsync
#define cudaMemcpyHostToDevice hipMemcpyHostToDevice
#define cudaMemcpyDeviceToHost hipMemcpyDeviceToHost
#define cudaMemcpyDeviceToDevice hipMemcpyDeviceToDevice
#define cudaStreamSynchronize hipStreamSynchronize

// The launch configuration of cudaLaunchKernelExC, the CUDA runtime's layout (gridDim, blockDim, dynamicSmemBytes,
// stream, attrs, numAttrs). The attributes are not used on AMD: a cooperative launch is refused below.
enum cudaLaunchAttributeID { cudaLaunchAttributeCooperative = 1 };
typedef struct cudaLaunchAttribute {
  enum cudaLaunchAttributeID id;
  union {
    int cooperative;
  } val;
} cudaLaunchAttribute;
typedef struct cudaLaunchConfig_t {
  dim3 gridDim;
  dim3 blockDim;
  size_t dynamicSmemBytes;
  cudaStream_t stream;
  cudaLaunchAttribute *attrs;
  unsigned int numAttrs;
} cudaLaunchConfig_t;

// The library and kernel calls of the kernel registry (lib/cuda/nfcxx_cuda.h).
static inline cudaError_t cudaLibraryLoadData(cudaLibrary_t *lib, const void *image, void *jit_opts, void *jit_vals,
                                              unsigned num_jit, void *lib_opts, void *lib_vals, unsigned num_lib) {
  (void)jit_opts; (void)jit_vals; (void)num_jit; (void)lib_opts; (void)lib_vals; (void)num_lib;
  return hipModuleLoadData(lib, image);
}
static inline cudaError_t cudaLibraryGetKernel(cudaKernel_t *kernel, cudaLibrary_t lib, const char *name) {
  return hipModuleGetFunction(kernel, lib, name);
}
static inline cudaError_t cudaLibraryUnload(cudaLibrary_t lib) { return hipModuleUnload(lib); }

// The launch of a kernel given as its cudaKernel_t (the registry maps the host address to it first).
static inline cudaError_t cudaLaunchKernelExC(const cudaLaunchConfig_t *cfg, const void *func, void **args) {
  if (cfg->numAttrs != 0) return cudaErrorNotSupported;  // cooperative and the other launch attributes
  return hipModuleLaunchKernel((hipFunction_t)func, cfg->gridDim.x, cfg->gridDim.y, cfg->gridDim.z, cfg->blockDim.x,
                               cfg->blockDim.y, cfg->blockDim.z, (unsigned)cfg->dynamicSmemBytes, cfg->stream, args, NULL);
}

// Declared for the templates of the CUDA-side headers; not implemented on AMD (see the note above).
static inline cudaError_t cudaFuncGetAttributes(cudaFuncAttributes *attr, const void *func) {
  (void)attr; (void)func; return cudaErrorNotSupported;
}
static inline cudaError_t cudaKernelSetAttributeForDevice(cudaKernel_t kernel, cudaFuncAttribute attr, int value, int device) {
  (void)kernel; (void)attr; (void)value; (void)device; return cudaErrorNotSupported;
}
static inline cudaError_t cudaOccupancyMaxActiveBlocksPerMultiprocessor(int *blocks, const void *func, int block_size,
                                                                        size_t smem) {
  (void)blocks; (void)func; (void)block_size; (void)smem; return cudaErrorNotSupported;
}
static inline cudaError_t cudaLaunchKernel(const void *func, dim3 grid, dim3 block, void **args, size_t smem,
                                           cudaStream_t stream) {
  (void)func; (void)grid; (void)block; (void)args; (void)smem; (void)stream; return cudaErrorNotSupported;
}
static inline cudaError_t cudaLaunchCooperativeKernel(const void *func, dim3 grid, dim3 block, void **args, size_t smem,
                                                      cudaStream_t stream) {
  (void)func; (void)grid; (void)block; (void)args; (void)smem; (void)stream; return cudaErrorNotSupported;
}

#endif  // NFCXX_HIP_CUDA_RUNTIME_H
