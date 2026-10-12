#include <cstdio>
#include "sub/helper.cuh"
__global__ void kernel(int *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = helper_value(i);
}
int main() {
  const int n = 256; int *d = 0; int h[256];
  cudaMalloc((void **)&d, sizeof h);
  kernel<<<(n + 127) / 128, 128>>>(d, n);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0; for (int i = 0; i < n; i++) bad += h[i] != 3 * i + 1;
  printf("include: %d elements, %d mismatches\n", n, bad);
  cudaFree(d);
  return bad != 0;
}
