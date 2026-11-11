// Template arguments deduced from expression arguments: a cast (const float *) raw gives its type, and a call that
// names only some template arguments (add_cuda<7>(...)) takes the rest from its own arguments (src + 0 is a float *).
// The rewriter used to refuse each of these (llama.cpp's diag, fill, concat, getrows, rope).
#include <cuda_runtime.h>
#include <stdio.h>

template <int K, typename T>
__global__ void addk(const T *src, T *dst, const int n) {
  int i = threadIdx.x;
  if (i < n) dst[i] = src[i] + (T)K;
}

template <int K, typename T>
static void add_cuda(const T *src, T *dst, const int n, cudaStream_t stream) {
  addk<K, T><<<1, n, 0, stream>>>(src, dst, n);
}

int main() {
  float *src = 0, *dst = 0;
  cudaMalloc((void **)&src, 4 * sizeof(float));
  cudaMalloc((void **)&dst, 4 * sizeof(float));
  float h[4] = {1, 2, 3, 4};
  cudaMemcpy(src, h, sizeof h, cudaMemcpyHostToDevice);
  void *raw = src;
  addk<5><<<1, 4>>>((const float *)raw, (float *)dst, 4);
  add_cuda<7>(src + 0, dst, 4, 0);
  cudaError_t err = cudaDeviceSynchronize();
  float out[4] = {0, 0, 0, 0};
  cudaMemcpy(out, dst, sizeof out, cudaMemcpyDeviceToHost);
  float sum = out[0] + out[1] + out[2] + out[3];
  printf("deduce cast: %s, sum %.1f\n", cudaGetErrorString(err), sum);
  cudaFree(src);
  cudaFree(dst);
  return sum != 38.0f;
}
