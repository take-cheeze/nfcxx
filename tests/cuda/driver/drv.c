// Driver API calls through the shim (scripts/cuda-driver-shim): each prints its CUresult; with the stand-in cudart the
// requests it made are printed too. The *_v2 and suffix-less names are the ones cuda.h binds the calls to.
#include <cuda.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {  // drv.cpp: the same program as C++ (nfcxx)
#endif
int per_thread_calls(void);  // drv_ptds.c: cuStreamQuery and cuMemcpy with the per-thread default stream
long fake_launched(void) __attribute__((weak));
#ifdef __cplusplus
}
#endif
int main(void) {
  const char *s, *n;
  CUresult r = cuInit(0);
  printf("cuInit %d\n", (int)r);
  int count = -1;
  r = cuDeviceGetCount(&count);
  printf("cuDeviceGetCount %d %d\n", (int)r, count);
  CUcontext ctx;
  printf("cuCtxCreate %d\n", (int)cuCtxCreate(&ctx, 0, 0));
  printf("cuCtxCreate_v4 %d\n", (int)cuCtxCreate_v4(&ctx, 0, 0, 0));
  CUuuid u;
  int a = cuDeviceGetUuid(&u, 0), b = cuDeviceGetUuid_v2(&u, 0);  // separate statements: a fixed order
  printf("cuDeviceGetUuid %d %d\n", a, b);
  float ms;
  a = cuEventElapsedTime(&ms, 0, 0);
  b = cuEventElapsedTime_v2(&ms, 0, 0);
  printf("cuEventElapsedTime %d %d\n", a, b);
  r = cuLaunchKernel((CUfunction)1, 2, 3, 4, 5, 6, 7, 8, (CUstream)9, (void **)10, (void **)11);
  printf("cuLaunchKernel %d %ld\n", (int)r, fake_launched ? fake_launched() : -1L);
  CUdeviceptr p;
  r = cuMemAlloc(&p, 64);
  cuGetErrorName(r, &n);
  cuGetErrorString(r, &s);
  printf("cuMemAlloc %d %s: %s\n", (int)r, n, s);
  CUmodule m;
  r = cuModuleLoad(&m, "x.cubin");
  cuGetErrorName(r, &n);
  printf("cuModuleLoad %d %s\n", (int)r, n);
  r = cuModuleLoad(&m, "x.cubin");  // resolved once: no second request
  printf("cuModuleLoad again %d\n", (int)r);
  printf("per thread %d\n", per_thread_calls());
  return 0;
}
