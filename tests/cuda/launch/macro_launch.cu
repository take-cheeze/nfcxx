// A launch inside a function-like macro (lightning-indexer.cu of llama.cpp): the macro's parameter gives the kernel's
// template argument. The rewriter expands the macro call before it scans for launches.
#include <cuda_runtime.h>
#include <stdio.h>

template <int N> __global__ void kern(int *p) { p[0] = N; }

#define LAUNCH(N)                 \
    kern<N>                       \
        <<<1, 1>>>(p);

int main() {
  int *p = 0;
  cudaMalloc((void **)&p, sizeof(int));
  LAUNCH(3)
  cudaError_t err = cudaGetLastError();
  int v = 0;
  cudaMemcpy(&v, p, sizeof v, cudaMemcpyDeviceToHost);
  printf("macro launch: %s, value %d\n", cudaGetErrorString(err), v);
  cudaFree(p);
  return v != 3;
}
