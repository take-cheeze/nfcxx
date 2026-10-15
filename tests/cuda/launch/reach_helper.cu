// The emitter lowers only the functions the kernel reaches: the kernel calls helper, helper calls leaf, and dead is
// never called (the IR keeps it; the emitter must not lower it). The result checks the reached chain exactly.
#include <cuda_runtime.h>
#include <stdio.h>

__device__ int leaf(int x) { return 2 * x; }
__device__ int helper(int x) { return leaf(x) + 1; }
__device__ int dead(int x) { return x * 7 + 100; }

__global__ void reach(const int *in, int *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = helper(in[i]);
}

int main() {
  const int N = 256;
  int hin[N], hout[N];
  for (int i = 0; i < N; i++) hin[i] = i - 100;
  int *din, *dout;
  cudaMalloc(&din, sizeof hin);
  cudaMalloc(&dout, sizeof hout);
  cudaMemcpy(din, hin, sizeof hin, cudaMemcpyHostToDevice);
  reach<<<(N + 127) / 128, 128>>>(din, dout, N);
  if (cudaDeviceSynchronize() != cudaSuccess) { printf("reach helper: launch failed\n"); return 1; }
  cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < N; i++) bad += hout[i] != 2 * hin[i] + 1;
  printf("reach helper: %d mismatches\n", bad);
  return bad != 0;
}
