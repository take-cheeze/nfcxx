// __launch_bounds__ on a kernel (18 files of llama.cpp's CUDA backend): a compile hint, so the launch path drops it.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void __launch_bounds__(128, 2) addk(const int *a, int *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) b[i] = a[i] + 1;
}

int main() {
  const int n = 256;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i;
  int *a = 0, *b = 0;
  cudaMalloc((void **)&a, sizeof h);
  cudaMalloc((void **)&b, sizeof o);
  cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice);
  addk<<<2, 128>>>(a, b, n);
  cudaError_t err = cudaGetLastError();
  cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] + 1;
  printf("launch_bounds: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(a);
  cudaFree(b);
  return bad != 0;
}
