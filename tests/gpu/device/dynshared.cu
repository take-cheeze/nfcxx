// Dynamic extern shared memory through the driver: each thread stages its element in a dynamically sized buffer
// (the launch passes the byte count, BLOCK * sizeof(float)) and writes it back plus one. Exact result: out[i] =
// in[i] + 1. Each thread reads only its own slot, so no barrier is needed; a barrier test waits for the host
// placeholder of __syncthreads (lib/cuda/nfcxx_cuda.h), which the host copy of a kernel needs.
#include <cuda_runtime.h>
#include <stdio.h>

#define N 1000
#define BLOCK 128

extern __shared__ float buf[];

__global__ void stage_plus_one(const float *in, float *out, int n) {
  int t = threadIdx.x;
  int i = blockIdx.x * blockDim.x + t;
  if (i < n) buf[t] = in[i];
  if (i < n) out[i] = buf[t] + 1.0f;
}

int main(void) {
  float h_in[N], h_out[N];
  for (int i = 0; i < N; i++) h_in[i] = (float)i;
  float *d_in = 0, *d_out = 0;
  if (cudaMalloc((void **)&d_in, sizeof h_in) || cudaMalloc((void **)&d_out, sizeof h_out)) return 2;
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  cudaMemset(d_out, 0, sizeof h_out);
  stage_plus_one<<<(N + BLOCK - 1) / BLOCK, BLOCK, BLOCK * sizeof(float)>>>(d_in, d_out, N);
  if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
    fprintf(stderr, "launch: %s\n", cudaGetErrorString(cudaGetLastError()));
    return 1;
  }
  cudaMemcpy(h_out, d_out, sizeof h_out, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < N; i++) bad += h_out[i] != h_in[i] + 1.0f;
  printf("dynshared: %d elements, %d mismatches\n", N, bad);
  cudaFree(d_in);
  cudaFree(d_out);
  return bad != 0;
}
