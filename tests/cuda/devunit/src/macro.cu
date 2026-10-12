// The device side of a macro that comes from an -I header through an angle include, and the launch that uses it.
// Run through the driver with -Itests/cuda/devunit/inc: prints "macro: 0 mismatches" when QK_K and QK_HALF are right.
#include "common.cuh"
#include <cstdio>

__global__ void k(int *p) { p[threadIdx.x] = QK_K + QK_HALF; }

int main() {
  int h[4], o[4] = {0, 0, 0, 0};
  int *d = 0;
  cudaMalloc((void **)&d, sizeof o);
  k<<<1, 4>>>(d);
  cudaMemcpy(o, d, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 4; i++) bad += o[i] != 256 + 128;
  printf("macro: %d mismatches\n", bad);
  cudaFree(d);
  (void)h;
  return bad != 0;
}
