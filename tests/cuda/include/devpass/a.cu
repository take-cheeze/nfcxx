// The kernel's body comes from a header next to this source (sub/kern.cuh), which includes a helper from its own
// directory (sub/helper.cuh): the device pass must find both, not only the host copy. Exact output checked below.
#include <cuda_runtime.h>
#include <stdio.h>
#include "sub/kern.cuh"

int main() {
  const int n = 8;
  int h[n];
  int *d = 0;
  cudaMalloc((void **)&d, sizeof h);
  scale_kernel<<<1, n>>>(d, 3);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += h[i] != 3 * i + 1;
  printf("devpass: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d);
  return bad != 0;
}
