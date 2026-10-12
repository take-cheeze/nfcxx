// Dynamic extern shared memory (13 files of llama.cpp's CUDA backend): `extern __shared__ T buf[]`, sized by the
// launch's third configuration item. The rewrite makes it a pointer from __nfcxx_dynshared_addr(); the emitter lowers
// that call to the .extern .shared symbol (not built yet: the device compile refuses it with exit 3).
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void dynk(int *b, int n) {
  extern __shared__ int buf[];
  int i = threadIdx.x;
  buf[i] = i * 3;
  __syncthreads();
  if (i < n) b[i] = buf[n - 1 - i];
}

int main() {
  const int n = 256;
  int o[n];
  int *b = 0;
  cudaMalloc((void **)&b, sizeof o);
  dynk<<<1, n, n * sizeof(int)>>>(b, n);
  cudaError_t err = cudaGetLastError();
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != (n - 1 - i) * 3;
  printf("dynamic shared: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(b);
  return bad != 0;
}
