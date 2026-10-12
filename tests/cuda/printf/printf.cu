// Device printf: a kernel prints from each of its threads. The runtime prints the lines when the kernel completes.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void hello(int n, float f) {
  if (threadIdx.x < n) printf("thread %d value %.2f\n", (int)threadIdx.x, f);
}

int main() {
  hello<<<1, 3>>>(3, 1.5f);
  cudaError_t err = cudaDeviceSynchronize();
  printf("sync: %s\n", cudaGetErrorString(err));
  return 0;
}
