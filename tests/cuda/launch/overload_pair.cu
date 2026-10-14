// Two overloads of one name (set-rows' set_rows_cuda): a three-parameter primary with a dependent launch, and a
// two-parameter overload that calls the primary with four arguments. The call is into another overload, not a cycle,
// so the launch is carried and the result is exact.
#include <cuda_runtime.h>
#include <stdio.h>

struct ctx_t { int dummy; };

template <typename src_t, typename idx_t, typename dst_t>
__global__ void rows_k(const src_t *s, const idx_t *ix, dst_t *d) {
  int k = threadIdx.x;
  d[k] = (dst_t)(s[k] + (src_t)ix[k]);
}

template <typename src_t, typename idx_t, typename dst_t>
static void rows_cuda(const src_t *s, const idx_t *ix, dst_t *d, int n) {
  rows_k<src_t, idx_t, dst_t><<<1, n>>>(s, ix, d);
}

template <typename src_t, typename idx_t>
static void rows_cuda(ctx_t &ctx, const src_t *s, const idx_t *ix, float *d, int n) {
  rows_cuda(s, ix, d, n);
}

template <typename T, typename I>
static void rows_quant(ctx_t &ctx, const T *s, const I *ix, float *d, int n) {
  rows_cuda<T, I>(ctx, s, ix, d, n);
}

int main() {
  const int n = 4;
  float hs[n] = {1, 2, 3, 4};
  int hi[n] = {10, 20, 30, 40};
  float hd[n] = {0, 0, 0, 0};
  float *s, *d;
  int *ix;
  cudaMalloc((void **)&s, sizeof(hs));
  cudaMalloc((void **)&ix, sizeof(hi));
  cudaMalloc((void **)&d, sizeof(hd));
  cudaMemcpy(s, hs, sizeof(hs), cudaMemcpyHostToDevice);
  cudaMemcpy(ix, hi, sizeof(hi), cudaMemcpyHostToDevice);
  ctx_t ctx{0};
  rows_quant<float, int>(ctx, s, ix, d, n);
  cudaDeviceSynchronize();
  cudaMemcpy(hd, d, sizeof(hd), cudaMemcpyDeviceToHost);
  int ok = hd[0] == 11 && hd[1] == 22 && hd[2] == 33 && hd[3] == 44;
  printf("overload pair: %s (%g %g %g %g)\n", ok ? "exact" : "mismatch", hd[0], hd[1], hd[2], hd[3]);
  cudaFree(s); cudaFree(ix); cudaFree(d);
  return ok ? 0 : 1;
}
