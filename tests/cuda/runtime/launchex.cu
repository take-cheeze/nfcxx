// cudaLaunchKernelEx with a registered kernel (ggml-cuda launches through it): the host function is looked up in the
// kernel registry as cudaLaunchKernel's is. Expect "launchex: no error, 0 mismatches".
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void scale(const int *in, int *out, int n, int k) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = in[i] * k;
}

int main() {
  const int n = 1000;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i - 300;
  int *a = 0, *b = 0;
  cudaMalloc((void **)&a, sizeof h);
  cudaMalloc((void **)&b, sizeof o);
  cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice);
  cudaLaunchConfig_t cfg = {};
  cfg.gridDim = dim3(8, 1, 1);
  cfg.blockDim = dim3(128, 1, 1);
  int k = 3;
  cudaError_t err = cudaLaunchKernelEx(&cfg, scale, a, b, n, k);
  if (err == cudaSuccess) err = cudaDeviceSynchronize();
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] * 3;
  printf("launchex: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(a);
  cudaFree(b);
  return bad != 0;
}
