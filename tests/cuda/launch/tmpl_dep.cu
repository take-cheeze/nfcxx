// A template launch whose template argument depends on an enclosing template parameter (the launch of
// ggml-cuda's templated kernels from a templated host function).
#include <cuda_runtime.h>
#include <stdio.h>

template <typename T, int S>
__global__ void scale_k(const T *a, T *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = a[i] * (T)S;
}

template <typename T>
void run_scale(const T *a, T *b, int n) {
  scale_k<T, 3><<<(n + 127) / 128, 128>>>(a, b, n);
}

int main() {
  const int n = 256;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i;
  int *a = 0, *b = 0;
  cudaMalloc((void **)&a, sizeof h);
  cudaMalloc((void **)&b, sizeof o);
  cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice);
  run_scale<int>(a, b, n);
  cudaError_t err = cudaGetLastError();
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] * 3;
  printf("template dependent: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
