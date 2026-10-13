// A template kernel whose last template argument is deduced from the call's arguments (softmax.cu of llama.cpp):
// soft_max_f32<true, 3><<<...>>>(p) gives T = float, from the declaration of p.
#include <cuda_runtime.h>
#include <stdio.h>

template <bool B, int N, typename T>
__global__ void kern(T *p) { p[0] = (T)(B ? N : 0); }

int main() {
  float *p = 0;
  cudaMalloc((void **)&p, sizeof(float));
  kern<true, 3><<<1, 1>>>(p);
  cudaError_t err = cudaGetLastError();
  float v = 0;
  cudaMemcpy(&v, p, sizeof v, cudaMemcpyDeviceToHost);
  printf("deduced launch: %s, value %.1f\n", cudaGetErrorString(err), v);
  cudaFree(p);
  return v != 3.0f;
}
