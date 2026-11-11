// A per-thread array indexed by an unrolled loop's counter: each element is a constant index in the copies, so the
// elements live in registers (pathb-ptx-emit's struct-slot analysis, through the unroll). The result is the host's.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(float *o, const float *in) {
  int i = threadIdx.x;
  float acc[4];
  #pragma unroll
  for (int j = 0; j < 4; j++) acc[j] = in[i] * (j + 1);
  float s = 0.0f;
  #pragma unroll
  for (int j = 0; j < 4; j++) s += acc[j];
  o[i] = s;
}

int main() {
  const int n = 32;
  float h_in[n], h_o[n];
  for (int i = 0; i < n; i++) h_in[i] = (float)(i - 9) * 0.5f;
  float *d_in, *d_o;
  cudaMalloc(&d_in, sizeof h_in);
  cudaMalloc(&d_o, sizeof h_o);
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d_in);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h_o, d_o, sizeof h_o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float e = 0.0f;
    for (int j = 0; j < 4; j++) e += h_in[i] * (j + 1);
    if (h_o[i] != e) bad++;
  }
  printf("array_slots: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d_in);
  cudaFree(d_o);
  return err != cudaSuccess || bad != 0;
}
