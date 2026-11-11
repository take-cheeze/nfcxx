/* The CUDA runtime calls of the tests/gpu launchers (launch*.c), on the HIP runtime: the launchers run the AMD code
   objects of tools/pathb-amdgpu-emit unchanged. A library is a HIP module (hipModuleLoadData), a kernel its function,
   and cudaLaunchKernelExC is hipModuleLaunchKernel with the argument array (the runtime packs it by the code object's
   metadata). Only what the launchers use is here. */
#ifndef NFCXX_CUDA_ON_HIP_H
#define NFCXX_CUDA_ON_HIP_H
#ifndef __HIP_PLATFORM_AMD__
#define __HIP_PLATFORM_AMD__
#endif
#include <hip/hip_runtime_api.h>

typedef hipError_t cudaError_t;
#define cudaSuccess hipSuccess
#define cudaGetErrorString hipGetErrorString
#define cudaGetLastError hipGetLastError
#define cudaDeviceSynchronize hipDeviceSynchronize
#define cudaMalloc hipMalloc
#define cudaFree hipFree
#define cudaMemset hipMemset
#define cudaMemcpy hipMemcpy
#define cudaMemcpyHostToDevice hipMemcpyHostToDevice
#define cudaMemcpyDeviceToHost hipMemcpyDeviceToHost

typedef hipModule_t cudaLibrary_t;
typedef hipFunction_t cudaKernel_t;
typedef struct {
  dim3 gridDim, blockDim;
  size_t dynamicSmemBytes;
  hipStream_t stream;
  void *attrs;
  unsigned numAttrs;
} cudaLaunchConfig_t;

static inline cudaError_t cudaLibraryLoadData(cudaLibrary_t *lib, const void *image, void *a, void *b, unsigned c, void *d,
                                              void *e, unsigned f) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
  return hipModuleLoadData(lib, image);
}
static inline cudaError_t cudaLibraryGetKernel(cudaKernel_t *k, cudaLibrary_t lib, const char *name) {
  return hipModuleGetFunction(k, lib, name);
}
static inline cudaError_t cudaLibraryUnload(cudaLibrary_t lib) { return hipModuleUnload(lib); }
static inline cudaError_t cudaLaunchKernelExC(const cudaLaunchConfig_t *cfg, const void *k, void **args) {
  return hipModuleLaunchKernel((hipFunction_t)k, cfg->gridDim.x, cfg->gridDim.y, cfg->gridDim.z, cfg->blockDim.x,
                               cfg->blockDim.y, cfg->blockDim.z, (unsigned)cfg->dynamicSmemBytes, cfg->stream, args, NULL);
}
#endif
