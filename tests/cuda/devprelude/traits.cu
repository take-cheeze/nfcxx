// std::is_same_v and std::is_same in device code (ggml-cuda's templates): the device unit has no host <type_traits>,
// so the prelude defines them over plain types, and std::is_same_v<A, B> is rewritten to the struct form.
#include <cuda_runtime.h>
#include <type_traits>
#include <stdio.h>
template <typename T> __device__ int pick(T) { return std::is_same_v<T, float> ? 1 : 0; }
template <typename T> __device__ int pick2(T) { return std::is_same<T, float>::value ? 10 : 0; }
template <typename T> __global__ void k(int *p, T v) { p[0] = pick(v); p[1] = pick2(v); }
int main() {
  int *d = 0; cudaMalloc((void **)&d, 16);
  k<float><<<1, 1>>>(d, 1.0f);
  cudaError_t e = cudaDeviceSynchronize();
  int h[2] = {0, 0}; cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  printf("%s float %d %d\n", cudaGetErrorString(e), h[0], h[1]);
  k<int><<<1, 1>>>(d, 1);
  e = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  printf("%s int %d %d\n", cudaGetErrorString(e), h[0], h[1]);
  return 0;
}
