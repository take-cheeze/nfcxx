// 8-bit integers on the device (signed char, unsigned char): loads, stores, wrapping arithmetic and conversions, checked
// against the same C++ on the host. The device emitter keeps a 1-byte value in a 32-bit register, sign- or zero-extended.
#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>

__global__ void k(const signed char *s, const unsigned char *u, signed char *os, unsigned char *ou, int *oi, int n) {
  int i = threadIdx.x;
  if (i < n) {
    signed char a = s[i];
    unsigned char b = u[i];
    os[i] = (signed char)(a + 3);     // wraps at 127
    ou[i] = (unsigned char)(b * 7);   // wraps at 255
    oi[i] = (int)a * 100 + (int)b;    // sign-extended and zero-extended conversions
  }
}

int main() {
  const int n = 256;
  signed char hs[n], gs[n];
  unsigned char hu[n], gu[n];
  int gi[n], ri[n];
  signed char rs[n];
  unsigned char ru[n];
  for (int i = 0; i < n; i++) {
    hs[i] = (signed char)(i - 128);
    hu[i] = (unsigned char)(i * 3);
    rs[i] = (signed char)(hs[i] + 3);
    ru[i] = (unsigned char)(hu[i] * 7);
    ri[i] = (int)hs[i] * 100 + (int)hu[i];
  }
  signed char *ds, *dos;
  unsigned char *du, *dou;
  int *doi;
  cudaMalloc((void **)&ds, n);
  cudaMalloc((void **)&du, n);
  cudaMalloc((void **)&dos, n);
  cudaMalloc((void **)&dou, n);
  cudaMalloc((void **)&doi, n * sizeof(int));
  cudaMemcpy(ds, hs, n, cudaMemcpyHostToDevice);
  cudaMemcpy(du, hu, n, cudaMemcpyHostToDevice);
  k<<<1, n>>>(ds, du, dos, dou, doi, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(gs, dos, n, cudaMemcpyDeviceToHost);
  cudaMemcpy(gu, dou, n, cudaMemcpyDeviceToHost);
  cudaMemcpy(gi, doi, n * sizeof(int), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += gs[i] != rs[i] || gu[i] != ru[i] || gi[i] != ri[i];
  printf("int8: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(ds); cudaFree(du); cudaFree(dos); cudaFree(dou); cudaFree(doi);
  return bad != 0;
}
