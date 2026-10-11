#line 1 "mul2.cu"
// The mul2 kernel of tests/gpu, written as CUDA source: launch syntax, runtime calls, and host code.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void mul2(const int *a, int *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = a[i] * 2;
}

__global__ void noargs() {}

int main() {
  const int n = 1000;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i - 300;
  int *a = 0, *b = 0;
  cudaMalloc((void **)&a, sizeof h);
  cudaMalloc((void **)&b, sizeof o);
  cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice);
  __nfcxx_cuda_launch(mul2, 8, 128, 0, 0, a, b, n);
  __nfcxx_cuda_launch(noargs, 1, 1, 0, 0);
  cudaError_t err = cudaGetLastError();
  printf("launch: %s\n", cudaGetErrorString(err));
  cudaFree(a);
  cudaFree(b);
  return 0;
}
