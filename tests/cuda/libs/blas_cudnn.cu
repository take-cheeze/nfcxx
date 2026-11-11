#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cudnn.h>
#include <stdio.h>
__global__ void twice(float *x, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) x[i] = 2.0f * x[i];
}
int main() {
  cublasHandle_t h = 0;
  cudnnHandle_t d = 0;
  cublasStatus_t s = cublasCreate(&h);
  cudnnStatus_t c = cudnnCreate(&d);
  float *x = 0;
  cudaMalloc((void **)&x, 4 * 1000);
  twice<<<8, 128>>>(x, 1000);
  printf("cublas=%d cudnn=%d launch=%d\n", (int)s, (int)c, (int)cudaGetLastError());
  cudaFree(x);
  return 0;
}
