// assert in device code: a condition that holds does nothing; the kernel's output is the value written.
#include <cuda_runtime.h>
#include <assert.h>
#include <stdio.h>
__device__ int checked(int x) { assert(x < 0); return x * 2; }
__global__ void k(int *p) { p[threadIdx.x] = checked((int)threadIdx.x); }
int main() {
  int *d = 0; cudaMalloc((void **)&d, 128);
  k<<<1, 32>>>(d);
  cudaError_t e = cudaDeviceSynchronize();
  int h[32]; cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  printf("%s %d\n", cudaGetErrorString(e), h[5]);
  return 0;
}
