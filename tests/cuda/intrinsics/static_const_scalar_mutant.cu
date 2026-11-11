// const and constexpr file-scope scalars read by device code: nvcc accepts them, and they are device constants here.
// The values are exact small integers, so the device and host results must match bit for bit.
#include <cuda_runtime.h>
#include <stdio.h>
static const int K = 4;
static constexpr float S = 0.5f;
__device__ float f(int i) { return (float)(K * i) * S; }
__global__ void k(float *out) {
  int i = threadIdx.x;
  if (i < 8) out[i] = f(i);
}
int main() {
  float h[8], *d;
  cudaMalloc(&d, sizeof h);
  k<<<1, 8>>>(d);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 8; i++)
    if (h[i] != (float)(3 * i) * 0.5f) bad++;
  printf("static const scalar: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
