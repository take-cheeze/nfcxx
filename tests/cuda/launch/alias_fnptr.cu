// A template alias for a function-pointer type used as a template parameter of a kernel (getrows.cu's
// dequantize_kq_t<dst_t>): `template <typename T> using dq_t = void (*)(...)` is carried into the device unit, so
// `template <typename T, dq_t<T> dq>` resolves. The device function dq is passed by address to the launch.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename dst_t>
using dq_t = void (*)(const float *x, long long ib, dst_t *y, int tid);

template <typename dst_t>
__device__ void dq_scale(const float *x, long long ib, dst_t *y, int tid) {
  y[tid] = (dst_t)(x[ib] * 2.0f + (float)tid);
}

template <typename dst_t, dq_t<dst_t> dq>
__global__ void k_rows(const float *src, dst_t *dst, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) dq(src, (long long)i, dst, i);
}

int main() {
  const int n = 4;
  float h[n] = {1.5f, 2.0f, -3.0f, 0.5f}, out[n];
  float *dsrc, *ddst;
  cudaMalloc(&dsrc, sizeof h); cudaMalloc(&ddst, sizeof h);
  cudaMemcpy(dsrc, h, sizeof h, cudaMemcpyHostToDevice);
  k_rows<float, dq_scale<float>><<<1, n>>>(dsrc, ddst, n);
  cudaMemcpy(out, ddst, sizeof out, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) if (out[i] != h[i] * 2.0f + (float)i) bad++;
  printf("alias fnptr: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
