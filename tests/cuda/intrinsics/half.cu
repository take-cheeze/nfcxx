// __float2half and __half2float on the device (halves given as bit patterns), against CUDA's own
// host conversions (cuda_fp16.h): round to nearest, even; subnormals; overflow to infinity; signed zero.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>
#include <string.h>

__global__ void k(unsigned short *h, float *back, const float *x) {
  unsigned i = threadIdx.x;
  h[i] = __half_as_ushort(__float2half(x[i]));
  back[i] = __half2float(__ushort_as_half(h[i]));
}

int main() {
  const float v[] = {1.0f, 0.5f, 2.0f, -2.5f, 65504.0f, 65520.0f, 1e5f, -1e5f, 1e-8f,
                     6.103515625e-05f, 5.9604644775390625e-08f, 3e-6f, 0.0f, -0.0f,
                     1.0009765625f, 1.00048828125f, 3.14159265f, 1234.5678f, -0.1f,
                     2.98023223876953125e-08f, 1.5f, 0.333333f, 100.0f, -7.25f,
                     1.0f / 3.0f, 2.0f / 3.0f, 0.001f, 12345.0f, -0.000123f, 9.5f,
                     0.75f, 42.0f};
  const int n = sizeof v / sizeof v[0];
  unsigned short hh[n];
  float hb[n];
  float *dx;
  unsigned short *dh;
  float *db;
  cudaMalloc((void **)&dx, sizeof v);
  cudaMalloc((void **)&dh, sizeof hh);
  cudaMalloc((void **)&db, sizeof hb);
  cudaMemcpy(dx, v, sizeof v, cudaMemcpyHostToDevice);
  k<<<1, n>>>(dh, db, dx);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hh, dh, sizeof hh, cudaMemcpyDeviceToHost);
  cudaMemcpy(hb, db, sizeof hb, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < n; i++) {
    __half ref = __float2half(v[i]);
    unsigned short rbits;
    memcpy(&rbits, &ref, sizeof rbits);
    float rback = __half2float(ref);
    bad += hh[i] != rbits;
    bad += memcmp(&hb[i], &rback, sizeof rback) != 0;
  }
  printf("half: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(dx); cudaFree(dh); cudaFree(db);
  return bad != 0;
}
