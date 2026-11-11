// A dependent template launch whose instance's address is taken too (softmax.cu's soft_max_f32<true, 0, 0>: the
// address goes to cudaFuncSetAttribute, then the instance is launched). The launch passes the host stub of the
// instance's wrapper, the attribute call passes the instance: the kernel table maps both to the one device entry.
// Then a launch of a host function with no device code: the error reaches cudaGetLastError (once), as with nvcc.
#include <cuda_runtime.h>
#include <stdio.h>

template <int N> __global__ void k(int *o) { o[threadIdx.x] = N * 100 + (int)threadIdx.x; }

template <int N> static void launch(int *o) {
  cudaFuncSetAttribute(k<N>, cudaFuncAttributeMaxDynamicSharedMemorySize, 0);
  k<N><<<1, 8>>>(o);
}

static void not_a_kernel(int *o) { (void)o; }

int main() {
  int *d;
  cudaMalloc(&d, 16 * sizeof(int));
  launch<3>(d);
  launch<5>(d + 8);
  cudaError_t launched = cudaGetLastError();
  int h[16];
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 8; i++) bad += (h[i] != 300 + i) + (h[8 + i] != 500 + i);
  void *args[] = {&d};
  cudaLaunchKernel((const void *)not_a_kernel, dim3(1), dim3(1), args, 0, 0);
  cudaError_t missing = cudaGetLastError(), after = cudaGetLastError();
  bad += missing != cudaErrorInvalidDeviceFunction;
  bad += after != cudaSuccess;
  printf("stub addr: %s, %s, %s, %d mismatches\n", cudaGetErrorString(launched), cudaGetErrorString(missing),
         cudaGetErrorString(after), bad);
  return bad != 0;
}
