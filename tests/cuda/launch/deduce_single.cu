// The only call of the enclosing template gives its argument's type (no explicit template argument): the instance is
// deduced from the argument, f<float>, and the kernel runs on the GPU.
#include <cuda_runtime.h>
#include <stdio.h>
template <typename T> __global__ void k(T *p) { p[0] = (T)1; }
template <typename T> void f(T *p) { k<T><<<1, 1>>>(p); }
int main() {
  float *d = 0;
  cudaMalloc((void **)&d, sizeof(float));
  f(d);
  cudaError_t err = cudaDeviceSynchronize();
  float h = 0;
  cudaMemcpy(&h, d, sizeof h, cudaMemcpyDeviceToHost);
  printf("deduce single: %s, value %g\n", cudaGetErrorString(err), h);
  return h != 1.0f;
}
