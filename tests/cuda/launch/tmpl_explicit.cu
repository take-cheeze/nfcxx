// A __global__ template kernel launched with explicit template arguments from a host function (the
// rewriter makes a wrapper per instance, declared at file scope). Not a dependent launch: the instance is fixed here.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename T, int S>
__launch_bounds__(128, 1)
static __global__ void scale_k(T *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = (T)(i * S);
}

int main() {
  const int n = 256;
  int *b = 0, o[n];
  cudaMalloc((void **)&b, sizeof o);
  scale_k<int, 3><<<(n + 127) / 128, 128>>>(b, n);
  cudaError_t e = cudaDeviceSynchronize();
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != i * 3;
  printf("templates: %s, %d mismatches\n", cudaGetErrorString(e), bad);
  cudaFree(b);
  return bad != 0;
}
