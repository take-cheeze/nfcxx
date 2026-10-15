#include <cstdio>
template <typename dst_t>
using dq_t = void (*)(const void *vx, long long ib, dst_t *y, int tid);

template <typename dst_t> static __device__ void dq_f32(const void *vx, long long ib, dst_t *y, int tid) {
  const float *x = (const float *) vx;
  y[tid] = (dst_t) (x[ib] * 2.0f);
}

template <typename dst_t, dq_t<dst_t> dq>
__global__ void k_rows(const void *src, dst_t *dst, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) dq(src, 0, dst, i);
}

int main() {
  float h[4] = {1.5f, 0, 0, 0}, *dsrc; float *dst; float out[4];
  cudaMalloc(&dsrc, 16); cudaMalloc(&dst, 16);
  cudaMemcpy(dsrc, h, 16, cudaMemcpyHostToDevice);
  k_rows<float, dq_f32<float>><<<1, 4>>>(dsrc, dst, 4);
  cudaMemcpy(out, dst, 16, cudaMemcpyDeviceToHost);
  printf("rows: %g %g\n", out[0], out[3]);
  return 0;
}
