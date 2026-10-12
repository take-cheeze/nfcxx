// Shared by two translation units: a kernel, and a __device__ helper that no launch reaches.
#pragma once
__device__ static int unused_helper(int x) { return x * 7 + 1; }

__global__ void addone(int *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = b[i] + 1;
}
