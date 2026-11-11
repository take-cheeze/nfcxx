// A small int8_t table read as uint32_t words, as llama.cpp's get_int_from_table_16 reads kvalues_mxfp4. nvcc declares
// the table .align 1 too; it works because the table lands aligned. Here a device printf string of odd length comes
// before it in the module, so the table must be aligned by its size (16) for the 32-bit loads.
#include <cuda_runtime.h>
#include <stdint.h>
#include <stdio.h>

static const __device__ int8_t tab[16] = {0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12};

__global__ void k(uint32_t *out, int n) {
  if (n < 0) printf("never printed: %d\n", n);
  const uint32_t *w = (const uint32_t *)tab;
  for (int i = 0; i < 4; i++) out[i] = w[i];
}

int main() {
  uint32_t *d, h[4];
  cudaMalloc(&d, sizeof h);
  k<<<1, 1>>>(d, 1);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  const uint32_t want[4] = {0x03020100u, 0x0c080604u, 0xfdfeff00u, 0xf4f8fafcu};
  int bad = 0;
  for (int i = 0; i < 4; i++) bad += err != cudaSuccess || h[i] != want[i];
  printf("table_align: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
