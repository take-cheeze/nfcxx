// Runtime calls ggml-cuda uses on the launch path: cudaFuncSetAttribute, the stream-ordered allocator and copies,
// and a kernel's address held in a variable and launched with cudaLaunchKernel (item 5 of the launch path).
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void addk(const int *a, int *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = a[i] + 1;
}

int main() {
  const int n = 256;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i;
  cudaStream_t s;
  cudaStreamCreate(&s);
  cudaError_t err = cudaFuncSetAttribute((const void *)addk, cudaFuncAttributeMaxDynamicSharedMemorySize, 0);
  int *a = 0, *b = 0;
  err = cudaMallocAsync((void **)&a, sizeof h, s);
  if (err == cudaSuccess) err = cudaMallocAsync((void **)&b, sizeof o, s);
  if (err == cudaSuccess) err = cudaMemcpyAsync(a, h, sizeof h, cudaMemcpyHostToDevice, s);
  void (*fp)(const int *, int *, int) = addk;
  int nn = n;
  void *args2[] = { &a, &b, &nn };
  dim3 grid(2, 1, 1), block(128, 1, 1);
  if (err == cudaSuccess) err = cudaLaunchKernel((const void *)fp, grid, block, args2, 0, s);
  if (err == cudaSuccess) err = cudaMemcpyAsync(o, b, sizeof o, cudaMemcpyDeviceToHost, s);
  if (err == cudaSuccess) err = cudaStreamSynchronize(s);
  if (err == cudaSuccess) err = cudaFreeAsync(a, s);
  if (err == cudaSuccess) err = cudaFreeAsync(b, s);
  if (err == cudaSuccess) err = cudaStreamSynchronize(s);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] + 1;
  printf("async: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaStreamDestroy(s);
  return bad != 0 || err != cudaSuccess;
}
