// A launch whose template argument depends on an enclosing template parameter (T): host_fn<float> is called from
// main, so the instance k<float> is the one the device image needs.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename T>
__global__ void k(T *p) { p[threadIdx.x] = (T)(threadIdx.x * 2); }

template <typename T>
void host_fn(T *p) { k<T><<<1, 32>>>(p); }

int main() {
  float *d = 0;
  float h[32];
  cudaMalloc((void **)&d, sizeof h);
  host_fn<float>(d);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 32; i++) bad += h[i] != (float)(i * 2);
  printf("dep type: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d);
  return bad != 0;
}
