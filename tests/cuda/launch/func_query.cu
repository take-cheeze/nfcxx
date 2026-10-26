// The runtime's queries on a kernel's host address (llama.cpp's launch_fattn calls
// cudaOccupancyMaxActiveBlocksPerMultiprocessor, common.cuh's PDL check cudaFuncGetAttributes): the kernels are loaded
// with cudaLibraryLoadData, so the runtime does not know the host address, and the call failed with "invalid resource
// handle". The macros in lib/cuda/nfcxx_cuda.h look the kernel up first, as for cudaFuncSetAttribute.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(float *x) { x[threadIdx.x] *= 2.0f; }

int main() {
  int bad = 0;
  int blocks = 0;
  cudaError_t e1 = cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks, k, 128, 0);
  bad += e1 != cudaSuccess;
  bad += blocks <= 0;
  cudaFuncAttributes attr = {};
  cudaError_t e2 = cudaFuncGetAttributes(&attr, k);
  bad += e2 != cudaSuccess;
  bad += attr.maxThreadsPerBlock <= 0;
  printf("func query: %s, %s, %d mismatches\n", cudaGetErrorString(e1), cudaGetErrorString(e2), bad);
  return bad != 0;
}
