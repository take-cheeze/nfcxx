// Unit B: launches the same kernel from its own copy of the header.
#include <cuda_runtime.h>
#include "kern.cuh"
int run_b(int *b, int n) {
  addone<<<1, n>>>(b, n);
  return cudaDeviceSynchronize() == cudaSuccess ? 0 : 1;
}
