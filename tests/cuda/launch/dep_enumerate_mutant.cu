// A dependent launch (mark<ncols1 * ncols2>, ncols1 and ncols2 are the template parameters of launch_outer) whose
// instances come from explicit calls nested in a switch template: the call's template argument `cols / 2` names a
// block-local constant of the switch body, and cols_per_block is the switch's own parameter. Two instances, exact result.
#include <cuda_runtime.h>
#include <stdio.h>

template <int ncols> __global__ void mark(int *out) {
  if (threadIdx.x == 0) out[ncols] = ncols;
}

template <int DV, int ncols1, int ncols2>
void launch_outer(int *out) {
  mark<ncols1 * ncols2><<<1, 32>>>(out);
}

template <int cols_per_block>
void switch_cols(int *out) {
  constexpr int cols = cols_per_block;
  launch_outer<8, cols / 4, 2>(out);
}

int main() {
  int *d = nullptr;
  if (cudaMalloc(&d, 32 * sizeof(int)) != cudaSuccess) return 1;
  cudaMemset(d, 0, 32 * sizeof(int));
  switch_cols<8>(d);    // ncols1 = 4, ncols2 = 2: mark<8> writes out[8] = 8
  switch_cols<16>(d);   // ncols1 = 8, ncols2 = 2: mark<16> writes out[16] = 16
  int h[32];
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  cudaFree(d);
  int bad = 0;
  for (int i = 0; i < 32; i++) {
    int want = (i == 8) ? 8 : (i == 16) ? 16 : 0;
    if (h[i] != want) bad++;
  }
  printf("dep enumerate: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
