// The device prelude's make_half2, powf, memcpy and memset (used by ggml-cuda's mmq.cu and common.cuh), on the GPU
// against the host. make_half2 and memcpy/memset are exact: their bits must match. powf is approximate (exp(y * log x)
// on the PTX of expf and logf), checked within |got - ref| <= 1e-5 * |ref| + 1e-6 against the host's powf.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { N = 2048 };

__global__ void kpre(const float *a, const float *b, const int *ia, unsigned *hm, unsigned *hmi, float *pw,
                     unsigned *bits, unsigned char *obuf) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= N) return;
  __half2 h = make_half2(a[i], b[i]);
  __half2 hi = make_half2(ia[i] & 15, ia[i] >> 4);
  unsigned u, v;
  memcpy(&u, &h, 4);
  memcpy(&v, &hi, 4);
  hm[i] = u;
  hmi[i] = v;
  float x = 0.5f + (i % 16) * 0.25f;
  float y = (i % 9 - 4) * 0.5f;
  pw[2 * i] = powf(x, y);
  pw[2 * i + 1] = powf(2.0f, y);
  unsigned w;
  memcpy(&w, &a[i], sizeof w);   /* a bit copy through memcpy */
  bits[i] = w;
  unsigned char *p = obuf + 16 * i;
  memset(p, 0x5a + (i & 1), 16); /* memset fills all 16 bytes */
  p[0] = (unsigned char)(p[0] + (i & 3));
}

static unsigned bits_of(float f) { unsigned u; memcpy(&u, &f, 4); return u; }
static unsigned hbits2(__half2 h) { unsigned u; memcpy(&u, &h, 4); return u; }

int main() {
  float *da, *db, *dpw; int *dia; unsigned *dhm, *dhmi, *dbits; unsigned char *dobuf;
  float ha[N], hb[N], hpw[2 * N];
  int hia[N];
  unsigned hhm[N], hhmi[N], hbits[N];
  unsigned char hobuf[16 * N];
  for (int i = 0; i < N; i++) {
    ha[i] = (float)((i * 7) % 13 - 6) + 0.5f * (i % 3);
    hb[i] = (float)((i * 5) % 9 - 4) * 0.25f;
    hia[i] = (i * 37) % 256;
  }
  cudaMalloc((void **)&da, sizeof ha); cudaMalloc((void **)&db, sizeof hb);
  cudaMalloc((void **)&dia, sizeof hia);
  cudaMalloc((void **)&dhm, sizeof hhm); cudaMalloc((void **)&dhmi, sizeof hhmi);
  cudaMalloc((void **)&dpw, sizeof hpw); cudaMalloc((void **)&dbits, sizeof hbits);
  cudaMalloc((void **)&dobuf, sizeof hobuf);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice);
  cudaMemcpy(db, hb, sizeof hb, cudaMemcpyHostToDevice);
  cudaMemcpy(dia, hia, sizeof hia, cudaMemcpyHostToDevice);
  kpre<<<(N + 127) / 128, 128>>>(da, db, dia, dhm, dhmi, dpw, dbits, dobuf);
  cudaMemcpy(hhm, dhm, sizeof hhm, cudaMemcpyDeviceToHost);
  cudaMemcpy(hhmi, dhmi, sizeof hhmi, cudaMemcpyDeviceToHost);
  cudaMemcpy(hpw, dpw, sizeof hpw, cudaMemcpyDeviceToHost);
  cudaMemcpy(hbits, dbits, sizeof hbits, cudaMemcpyDeviceToHost);
  cudaMemcpy(hobuf, dobuf, sizeof hobuf, cudaMemcpyDeviceToHost);
  if (cudaGetLastError() != cudaSuccess) { printf("prelude gaps: CUDA error\n"); return 1; }

  int bad = 0;
  double max_rel = 0.0;
  for (int i = 0; i < N; i++) {
    __half2 r = make_half2(__float2half(ha[i]), __float2half(hb[i]));
    if (hbits2(r) != hhm[i]) bad++;
    __half2 ri = make_half2(__float2half((float)(hia[i] & 15)), __float2half((float)(hia[i] >> 4)));
    if (hbits2(ri) != hhmi[i]) bad++;
    if (hbits[i] != bits_of(ha[i])) bad++;
    float x = 0.5f + (i % 16) * 0.25f;
    float y = (i % 9 - 4) * 0.5f;
    float refs[2] = { powf(x, y), powf(2.0f, y) };
    for (int k = 0; k < 2; k++) {
      float got = hpw[2 * i + k], ref = refs[k];
      double err = fabs((double)got - (double)ref);
      if (err > 1e-5 * fabs((double)ref) + 1e-6) bad++;
      if (fabs((double)ref) > 1e-3) { double rel = err / fabs((double)ref); if (rel > max_rel) max_rel = rel; }
    }
    for (int j = 0; j < 16; j++) {
      unsigned char want = (unsigned char)(0x5a + (i & 1));
      if (j == 0) want = (unsigned char)(want + (i & 3));
      if (hobuf[16 * i + j] != want) { bad++; break; }
    }
  }
  if (bad) { printf("prelude gaps: %d mismatches\n", bad); return 1; }
  printf("prelude gaps: no error, 0 mismatches, powf max rel err %.2e\n", max_rel);
  return 0;
}
