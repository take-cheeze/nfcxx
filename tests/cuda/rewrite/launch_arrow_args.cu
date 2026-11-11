// Launch arguments that are casts of member accesses and divisions (the clamp.cu, col2im-1d.cu and snake.cu shapes):
// the rewriter splits the argument list at top-level commas (a `->` is an operator, not a bracket), and it deduces the
// template argument T from the cast `(const float *)` as a call site does. Checked exactly against the host.
#include <cuda_runtime.h>
#include <stdio.h>

struct Buf { float *data; int nb[4]; };

template <typename T>
__global__ void scale_k(const T *x, T *dst, int n, int s1, int s2, int s3, int s4, int s5, int s6) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) dst[i] = x[i] * (T)(s1 + s2 + s3 + s4 + s5 + s6);
}

int main() {
  const int n = 64;
  Buf src, dst;
  float hx[n], *dx, *dd;
  for (int i = 0; i < n; i++) hx[i] = (float)(i % 7);
  cudaMalloc((void **)&dx, n * sizeof(float));
  cudaMalloc((void **)&dd, n * sizeof(float));
  cudaMemcpy(dx, hx, sizeof hx, cudaMemcpyHostToDevice);
  src.data = dx; dst.data = dd;
  for (int k = 0; k < 4; k++) { src.nb[k] = 8 * (k + 1); dst.nb[k] = 4 * (k + 1); }
  const Buf *ps = &src;
  const Buf *pd = &dst;
  scale_k<<<(n + 31) / 32, 32>>>((const float *)ps->data, (float *)pd->data, n,
                                 ps->nb[1] / 2, ps->nb[2] / 2, ps->nb[3] / 2,
                                 pd->nb[1] / 2, pd->nb[2] / 2, pd->nb[3] / 2);
  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("launch arrow args: kernel error %s\n", cudaGetErrorString(err));
    return 1;
  }
  float out[n];
  cudaMemcpy(out, dd, sizeof out, cudaMemcpyDeviceToHost);
  // src strides 16, 24, 32 halved: 8+12+16 = 36; dst strides 8, 12, 16 halved: 4+6+8 = 18. The factor is 54.
  int bad = 0;
  for (int i = 0; i < n; i++) bad += out[i] != hx[i] * 54.0f;
  printf("launch arrow args: no error, %d mismatches\n", bad);
  return bad != 0;
}
