// Unit A: owns main; runs the kernel from unit B as well.
#include <cuda_runtime.h>
#include <stdio.h>
#include "kern.cuh"
int run_b(int *b, int n);
int main() {
  const int n = 256;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i;
  int *b = 0;
  cudaMalloc((void **)&b, sizeof h);
  cudaMemcpy(b, h, sizeof h, cudaMemcpyHostToDevice);
  addone<<<1, n>>>(b, n);
  run_b(b, n);
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] + 2;
  printf("linkage: %d mismatches\n", bad);
  cudaFree(b);
  return bad != 0;
}
