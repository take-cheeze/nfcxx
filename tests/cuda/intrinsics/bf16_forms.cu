// The bf16 forms that ggml-cuda uses: __float2bfloat16 / __bfloat162float, the pair forms __float22bfloat162_rn and
// __bfloat1622float2, and __low2bfloat16 / __high2bfloat16. Round to nearest even, as CUDA's conversions. The host copy
// uses CUDA's own types (cuda_bf16.h); the device uses the prelude's. Results are compared bit for bit with the host.
#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <stdio.h>
#include <string.h>

template <typename T> __host__ __device__ unsigned short bits16(T v) { return *reinterpret_cast<const unsigned short *>(&v); }

// Inputs: ties to even (0x3f808000 down, 0x3f818000 up), just above and below a rounding boundary, 2.5 exact, NaN, +-inf,
// the smallest denormal, -2, 10, 0.1.
#define N 12

__global__ void k(const float *f, unsigned short *bits, float *back, unsigned short *pair, float *pairback, float *lows) {
  int i = threadIdx.x;
  if (i < N) {
    __nv_bfloat16 b = __float2bfloat16(f[i]);
    bits[i] = bits16(b);
    back[i] = __bfloat162float(b);
  }
  if (i < N / 2) {
    __nv_bfloat162 h = __float22bfloat162_rn(make_float2(f[2 * i], f[2 * i + 1]));
    pair[2 * i] = bits16(h.x);
    pair[2 * i + 1] = bits16(h.y);
    float2 g = __bfloat1622float2(h);
    pairback[2 * i] = g.x;
    pairback[2 * i + 1] = g.y;
    lows[2 * i] = __bfloat162float(__low2bfloat16(h));
    lows[2 * i + 1] = __bfloat162float(__high2bfloat16(h));
  }
}

static unsigned as_bits(float v) { unsigned u; memcpy(&u, &v, sizeof u); return u; }

int main() {
  const unsigned fb[N] = {0x3f808000u, 0x3f818000u, 0x3f800001u, 0x3f80ffffu, 0x40200000u, 0x7fc00001u,
                          0x7f800000u, 0xff800000u, 0x00000001u, 0xc0000000u, 0xffc00001u, 0x3dcccccdu};
  float f[N];
  memcpy(f, fb, sizeof f);

  float *df, *dback, *dpairback, *dlows;
  unsigned short *dbits, *dpair;
  cudaMalloc((void **)&df, sizeof f);
  cudaMalloc((void **)&dbits, N * sizeof(unsigned short));
  cudaMalloc((void **)&dback, N * sizeof(float));
  cudaMalloc((void **)&dpair, N * sizeof(unsigned short));
  cudaMalloc((void **)&dpairback, N * sizeof(float));
  cudaMalloc((void **)&dlows, N * sizeof(float));
  cudaMemcpy(df, f, sizeof f, cudaMemcpyHostToDevice);
  k<<<1, N>>>(df, dbits, dback, dpair, dpairback, dlows);

  unsigned short dbit[N], dpr[N];
  float dbk[N], dpb[N], dlw[N];
  cudaMemcpy(dbit, dbits, sizeof dbit, cudaMemcpyDeviceToHost);
  cudaMemcpy(dbk, dback, sizeof dbk, cudaMemcpyDeviceToHost);
  cudaMemcpy(dpr, dpair, sizeof dpr, cudaMemcpyDeviceToHost);
  cudaMemcpy(dpb, dpairback, sizeof dpb, cudaMemcpyDeviceToHost);
  cudaMemcpy(dlw, dlows, sizeof dlw, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < N; i++) {
    __nv_bfloat16 hb = __float2bfloat16(f[i]);
    bad += bits16(hb) != dbit[i];
    bad += as_bits(__bfloat162float(hb)) != as_bits(dbk[i]);
  }
  for (int i = 0; i < N / 2; i++) {
    __nv_bfloat162 hh = __float22bfloat162_rn(make_float2(f[2 * i], f[2 * i + 1]));
    float2 g = __bfloat1622float2(hh);
    bad += bits16(hh.x) != dpr[2 * i];
    bad += bits16(hh.y) != dpr[2 * i + 1];
    bad += as_bits(g.x) != as_bits(dpb[2 * i]);
    bad += as_bits(g.y) != as_bits(dpb[2 * i + 1]);
    bad += as_bits(__bfloat162float(__low2bfloat16(hh))) != as_bits(dlw[2 * i]);
    bad += as_bits(__bfloat162float(__high2bfloat16(hh))) != as_bits(dlw[2 * i + 1]);
  }
  printf("bf16 forms: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
