// __hadd, __hmul and __hfma on the device (the device unit's half type is an unsigned short), against the same
// operations on the host with CUDA's conversions (cuda_fp16.h): the float result of the operands, rounded to half.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>
#include <string.h>

// The host copy of the kernel needs __hfma, which the CUDA host headers do not declare; the device pass uses the
// prelude's. This host function is not kept in the device unit.
static __half __hfma(__half a, __half b, __half c) {
  return __float2half(__half2float(a) * __half2float(b) + __half2float(c));
}

__global__ void k(unsigned short *s, unsigned short *p, unsigned short *f, const unsigned short *a,
                  const unsigned short *b, const unsigned short *c) {
  unsigned i = threadIdx.x;
  __half x = (__half)a[i];
  __half y = (__half)b[i];
  __half z = (__half)c[i];
  __half sum = __hadd(x, y);
  __half prod = __hmul(x, y);
  __half fma = __hfma(x, y, z);
  s[i] = *(unsigned short *)&sum;
  p[i] = *(unsigned short *)&prod;
  f[i] = *(unsigned short *)&fma;
}

int main() {
  const float v[] = {1.0f, 0.5f, 2.0f, -2.5f, 1.5f, 2.25f, -0.75f, 1024.0f, 0.0009765625f, 3.0f, 0.333251953125f,
                     -7.25f, 65504.0f, 0.1f, 100.0f, 1.0009765625f};
  const int m = sizeof v / sizeof v[0];
  const int n = m * m;
  unsigned short ha[n], hb[n], hc[n], rs[n], rp[n], rf[n];
  for (int i = 0; i < n; i++) {
    __half x = __float2half(v[i / m]);
    __half y = __float2half(v[i % m]);
    __half z = __float2half(v[(i * 7) % m]);
    memcpy(&ha[i], &x, 2);
    memcpy(&hb[i], &y, 2);
    memcpy(&hc[i], &z, 2);
  }
  unsigned short *da, *db, *dc, *ds, *dp, *df;
  cudaMalloc((void **)&da, sizeof ha); cudaMalloc((void **)&db, sizeof hb); cudaMalloc((void **)&dc, sizeof hc);
  cudaMalloc((void **)&ds, sizeof rs); cudaMalloc((void **)&dp, sizeof rp); cudaMalloc((void **)&df, sizeof rf);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice);
  cudaMemcpy(db, hb, sizeof hb, cudaMemcpyHostToDevice);
  cudaMemcpy(dc, hc, sizeof hc, cudaMemcpyHostToDevice);
  k<<<1, n>>>(ds, dp, df, da, db, dc);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(rs, ds, sizeof rs, cudaMemcpyDeviceToHost);
  cudaMemcpy(rp, dp, sizeof rp, cudaMemcpyDeviceToHost);
  cudaMemcpy(rf, df, sizeof rf, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < n; i++) {
    __half x, y, z;
    memcpy(&x, &ha[i], 2); memcpy(&y, &hb[i], 2); memcpy(&z, &hc[i], 2);
    float fx = __half2float(x), fy = __half2float(y), fz = __half2float(z);
    __half es = __float2half(fx + fy), ep = __float2half(fx * fy), ef = __float2half(fx * fy + fz);
    unsigned short bs, bp, bf;
    memcpy(&bs, &es, 2); memcpy(&bp, &ep, 2); memcpy(&bf, &ef, 2);
    bad += rs[i] != bs;
    bad += rp[i] != bp;
    bad += rf[i] != bf;
  }
  printf("half arith: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(da); cudaFree(db); cudaFree(dc); cudaFree(ds); cudaFree(dp); cudaFree(df);
  return bad != 0;
}
