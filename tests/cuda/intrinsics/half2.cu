// __half2 (two halves packed in one 32-bit value) and its pair functions on the device, against the same operations on
// the host with CUDA's conversions (cuda_fp16.h). Each lane of __hadd2 and __hmul2 is the float result rounded to half.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>
#include <string.h>

__global__ void k(const unsigned short *a, unsigned short *o, int n) {
  int i = threadIdx.x;
  if (i < n) {
    __half x = (__half)a[4 * i];
    __half y = (__half)a[4 * i + 1];
    __half z = (__half)a[4 * i + 2];
    __half w = (__half)a[4 * i + 3];
    __half2 h = __halves2half2(x, y);
    __half2 g = __halves2half2(z, w);
    __half2 hs = __hadd2(h, g);
    __half2 hm = __hmul2(h, g);
    __half2 bc = __half2half2(x);
    __half2 lo = __lows2half2(h, g);
    __half2 hi = __highs2half2(h, g);
    o[12 * i + 0] = (unsigned short)__low2half(h);
    o[12 * i + 1] = (unsigned short)__high2half(h);
    o[12 * i + 2] = (unsigned short)__low2half(hs);
    o[12 * i + 3] = (unsigned short)__high2half(hs);
    o[12 * i + 4] = (unsigned short)__low2half(hm);
    o[12 * i + 5] = (unsigned short)__high2half(hm);
    o[12 * i + 6] = (unsigned short)__low2half(bc);
    o[12 * i + 7] = (unsigned short)__high2half(bc);
    o[12 * i + 8] = (unsigned short)__low2half(lo);
    o[12 * i + 9] = (unsigned short)__high2half(lo);
    o[12 * i + 10] = (unsigned short)__low2half(hi);
    o[12 * i + 11] = (unsigned short)__high2half(hi);
  }
}

static unsigned short bits(__half h) { unsigned short u; memcpy(&u, &h, 2); return u; }

int main() {
  const float v[] = {1.0f, 0.5f, -2.5f, 65504.0f, 0.1f, 3.0f, 0.0000610352f, 1024.0f};
  const int m = sizeof v / sizeof v[0];
  const int n = m * m;
  unsigned short ha[4 * n], ho[12 * n], ro[12 * n];
  for (int i = 0; i < n; i++) {
    __half x = __float2half(v[i / m]), y = __float2half(v[i % m]);
    __half z = __float2half(v[(i * 5) % m]), w = __float2half(v[(i * 3 + 1) % m]);
    ha[4 * i] = bits(x); ha[4 * i + 1] = bits(y); ha[4 * i + 2] = bits(z); ha[4 * i + 3] = bits(w);
    // Expected lanes: the host result of each lane, rounded to half as the device does.
    ro[12 * i + 0] = bits(x);
    ro[12 * i + 1] = bits(y);
    __half sx = __float2half(__half2float(x) + __half2float(z)), sy = __float2half(__half2float(y) + __half2float(w));
    ro[12 * i + 2] = bits(sx); ro[12 * i + 3] = bits(sy);
    __half mx = __float2half(__half2float(x) * __half2float(z)), my = __float2half(__half2float(y) * __half2float(w));
    ro[12 * i + 4] = bits(mx); ro[12 * i + 5] = bits(my);
    ro[12 * i + 6] = bits(x); ro[12 * i + 7] = bits(x);
    ro[12 * i + 8] = bits(x); ro[12 * i + 9] = bits(z);
    ro[12 * i + 10] = bits(y); ro[12 * i + 11] = bits(w);
  }
  unsigned short *da, *dout;
  cudaMalloc((void **)&da, sizeof ha);
  cudaMalloc((void **)&dout, sizeof ho);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice);
  k<<<1, n>>>(da, dout, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 12 * n; i++) bad += ho[i] != ro[i];
  printf("half2: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(da); cudaFree(dout);
  return bad != 0;
}
