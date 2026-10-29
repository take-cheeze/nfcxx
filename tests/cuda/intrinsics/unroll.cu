// `#pragma unroll` on the loops of device code: the result is the host's, whether or not the loop is unrolled. A loop
// with a constant trip count is unrolled by the driver (pathb-ptx-emit), as nvcc does; the others stay loops. The
// accumulator, a loop that uses its counter as an index, a loop with a count argument, and a loop whose trip count is
// not a constant (only the first iteration runs under the guard) are checked against the host.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(int *o, const int *in, int n) {
  int i = threadIdx.x;
  int acc = 0;
#pragma unroll
  for (int j = 0; j < 8; j++) acc += in[i] * (j + 1);
  o[i] = acc;
  int t = 0;
#pragma unroll 4
  for (int j = 0; j < 6; j++) t += in[(i + j) & 31] ^ j;
  o[32 + i] = t;
  int g = 0;
#pragma unroll
  for (int j = 0; j < n; j++) g += in[i] + j;
  o[64 + i] = g;
}

int main() {
  const int n = 32;
  int h_in[n], h[96], want = 0;
  for (int i = 0; i < n; i++) h_in[i] = (i * 37) % 211 - 60;
  int *d_in, *d_o;
  cudaMalloc(&d_in, sizeof h_in);
  cudaMalloc(&d_o, sizeof h);
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d_in, 5);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d_o, sizeof h, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) {
    int acc = 0;
    for (int j = 0; j < 8; j++) acc += h_in[i] * (j + 1);
    int t = 0;
    for (int j = 0; j < 6; j++) t += h_in[(i + j) & 31] ^ j;
    int g = 0;
    for (int j = 0; j < 5; j++) g += h_in[i] + j;
    if (h[i] != acc) want++;
    if (h[32 + i] != t) want++;
    if (h[64 + i] != g) want++;
  }
  printf("unroll: %s, %d mismatches\n", cudaGetErrorString(err), want);
  cudaFree(d_in);
  cudaFree(d_o);
  return err != cudaSuccess || want != 0;
}
