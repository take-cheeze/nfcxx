// A template argument with a comment in it (ggml-cuda's `reduce_rows_f32</*norm=*/true>`): the host copy and the device
// unit must name the launch wrapper the same way. The device pass blanks comments, so a host wrapper name that kept
// the comment would be undefined where the module's kernel table refers to it.
#include <cuda_runtime.h>
#include <stdio.h>

template <bool NORM> __global__ void kern(int *p) { p[0] = NORM ? 5 : 2; }

int main() {
  int *p = 0;
  cudaMalloc((void **)&p, sizeof(int));
  kern</*norm=*/true><<<1, 1>>>(p);
  cudaError_t err = cudaGetLastError();
  int v = 0;
  cudaMemcpy(&v, p, sizeof v, cudaMemcpyDeviceToHost);
  printf("comment targs: %s, value %d\n", cudaGetErrorString(err), v);
  cudaFree(p);
  return v != 5;
}
