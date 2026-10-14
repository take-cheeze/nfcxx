// Grid-wide cooperative groups sync (softmax.cu of llama.cpp): this_grid().sync() between two phases, launched with
// cudaLaunchCooperativeKernel. Phase 1 writes a[i] for every element; phase 2 reads a neighbouring block's a[] (which
// only the barrier makes visible) and writes b[]. grid_sync_nobarrier.cu is the same kernel without the sync (a mutant).
#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <stdio.h>

namespace cg = cooperative_groups;

__global__ void two_phase(int *a, int *b, int n) {
  cg::grid_group g = cg::this_grid();
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  // Block 0 is slow to write its part, so a block that reads it without the barrier sees stale data.
  if (blockIdx.x == 0) {
    int acc = 0;
    for (int k = 0; k < 4000000; k++) acc += (k ^ n) & 3;
    if (acc == -1) a[0] = acc;
  }
  if (i < n) a[i] = i * 3 + 1;
  g.sync();
  if (i < n) b[i] = a[(i + n / 2) % n] + 1;
}

int main() {
  const int n = 4096, block = 128, grid = n / block;
  int *a = 0, *b = 0;
  cudaMalloc((void **)&a, n * sizeof(int));
  cudaMalloc((void **)&b, n * sizeof(int));
  cudaMemset(a, 0, n * sizeof(int));
  cudaMemset(b, 0, n * sizeof(int));
  int nn = n;
  void *args[] = {&a, &b, &nn};
  cudaError_t err = cudaLaunchCooperativeKernel((void *)two_phase, dim3(grid), dim3(block), args, 0, 0);
  if (err == cudaSuccess) err = cudaDeviceSynchronize();
  int h[n];
  cudaMemcpy(h, b, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    int j = (i + n / 2) % n;
    bad += h[i] != j * 3 + 1 + 1;
  }
  printf("grid sync: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(a);
  cudaFree(b);
  return bad != 0;
}
