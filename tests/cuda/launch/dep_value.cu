// A launch whose template argument depends on an enclosing non-type parameter (N): host_v<3> and host_v<5> are
// called from main, so two instances of k are needed.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename T, int N>
__global__ void kv(T *p) { p[threadIdx.x] = (T)(threadIdx.x * N); }

template <int N>
void host_v(float *p) { kv<float, N><<<1, 32>>>(p); }

int main() {
  float *d = 0;
  float h[32];
  cudaMalloc((void **)&d, sizeof h);
  host_v<3>(d);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 32; i++) bad += h[i] != (float)(i * 3);
  host_v<5>(d);
  err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  for (int i = 0; i < 32; i++) bad += h[i] != (float)(i * 5);
  printf("dep value: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d);
  return bad != 0;
}
