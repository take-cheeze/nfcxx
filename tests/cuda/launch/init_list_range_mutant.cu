// A range-based for over a braced list in device code (llama.cpp's fattn-mma kernels): needs std::initializer_list in the
// device unit. Each thread sums the strides {w, w/2, w/4} of w = 8, so every element must be 14.
#include <cstdio>
#include <cuda_runtime.h>

__global__ void sum_strides(int *out, int w) {
  int s = 0;
  for (int stride : {w, w / 2, w / 8}) s += stride;
  out[threadIdx.x] = s;
}

int main() {
  const int n = 32, want = 14;
  int *d = nullptr;
  cudaMalloc(&d, n * sizeof(int));
  sum_strides<<<1, n>>>(d, 8);
  int h[n];
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += h[i] != want;
  printf("init list: no error, %d mismatches\n", bad);
  cudaFree(d);
  return 0;
}
