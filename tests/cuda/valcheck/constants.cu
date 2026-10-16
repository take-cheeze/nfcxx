// Value check of the constant and type helpers of the phase-2 emitter port (tools/pathb-ptx-emit/lower_types.cpp):
// float literals, integer constants and wrapping, sizeof and type widths, bool, and scalar constant globals
// (float, double, integer, bool and 64-bit initializers). Built with nvcc and with nfcxx; both runs must print the
// same values.
#include <cuda_runtime.h>
#include <stdint.h>
#include <stdio.h>

__device__ const float cf0 = 0.5f;
__device__ const float cf1 = -0.0f;
__device__ const float cf2 = 1.5e-3f;
__device__ const float cf3 = 3.4028235e38f;
__device__ const float cfk = 0.1f;
__device__ const double cd0 = 0.1;
__device__ const int cb0 = 250;
__device__ const int cb1 = -56;
__device__ const int cs0 = -300;
__device__ const int ci0 = -8;
__device__ const unsigned int cu0 = 0xfffffff0u;
__device__ const bool cbt = true;
__device__ const bool cbf = false;
__device__ const unsigned long long cbig = 0xfedcba9876543210ULL;
__device__ const long long cneg = -9223372036854775807LL - 1;

__global__ void values(uint32_t *out, float *fo, double *dout) {
  if (threadIdx.x) return;
  int k = 0;
  int f = 0;
  float zero = 0.0f;
  fo[f++] = 0.5f;
  fo[f++] = -0.0f;
  fo[f++] = 1e-45f;
  fo[f++] = 3.4028235e38f;
  fo[f++] = 0.1f;
  fo[f++] = 1.5e-3f;
  fo[f++] = 1.0f / zero;
  fo[f++] = -1.0f / zero;
  fo[f++] = zero / zero;
  fo[f++] = cf0;
  fo[f++] = cf1;
  fo[f++] = cf2;
  fo[f++] = cf3;
  fo[f++] = cfk;
  dout[0] = cd0;
  dout[1] = 0.1;
  out[k++] = 0xffffffffu;
  out[k++] = (uint32_t)(-1);
  out[k++] = (uint32_t)((unsigned long long)0xfedcba9876543210ULL >> 32);
  out[k++] = (uint32_t)(0xfedcba9876543210ULL);
  out[k++] = (uint32_t)(unsigned char)200;
  out[k++] = (uint32_t)(signed char)(-56);
  out[k++] = (uint32_t)(short)(-300);
  out[k++] = (uint32_t)(unsigned short)65535;
  out[k++] = (uint32_t)sizeof(char);
  out[k++] = (uint32_t)sizeof(short);
  out[k++] = (uint32_t)sizeof(int);
  out[k++] = (uint32_t)sizeof(long long);
  out[k++] = (uint32_t)sizeof(float);
  out[k++] = (uint32_t)sizeof(double);
  out[k++] = (uint32_t)sizeof(bool);
  out[k++] = (uint32_t)sizeof(void *);
  bool bt = true, bf = false;
  out[k++] = bt ? 11u : 22u;
  out[k++] = bf ? 11u : 22u;
  out[k++] = (uint32_t)(bt == 1);
  out[k++] = (uint32_t)cb0;
  out[k++] = (uint32_t)(int)cb1;
  out[k++] = (uint32_t)(int)cs0;
  out[k++] = (uint32_t)ci0;
  out[k++] = cu0;
  out[k++] = (uint32_t)cbt;
  out[k++] = (uint32_t)cbf;
  out[k++] = (uint32_t)(cbig >> 32);
  out[k++] = (uint32_t)cbig;
  out[k++] = (uint32_t)(cneg >> 32);
  out[k++] = (uint32_t)cneg;
  out[k++] = (uint32_t)(-2147483647 - 1);
  out[k++] = (uint32_t)(1ull << 40 >> 33);
  out[k++] = (uint32_t)(0x7fffffffu + 1u);
}

int main() {
  const int n = 32, nf = 14;
  uint32_t h[n];
  float hf[nf];
  double hd[2];
  uint32_t *d = 0;
  float *df = 0;
  double *dd = 0;
  cudaMalloc((void **)&d, sizeof h);
  cudaMalloc((void **)&df, sizeof hf);
  cudaMalloc((void **)&dd, sizeof hd);
  values<<<1, 32>>>(d, df, dd);
  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("error: %s\n", cudaGetErrorString(err));
    return 1;
  }
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  cudaMemcpy(hf, df, sizeof hf, cudaMemcpyDeviceToHost);
  cudaMemcpy(hd, dd, sizeof hd, cudaMemcpyDeviceToHost);
  cudaFree(d);
  cudaFree(df);
  cudaFree(dd);
  for (int i = 0; i < nf; i++) printf("f%d %a\n", i, (double)hf[i]);
  printf("d0 %a\nd1 %a\n", hd[0], hd[1]);
  for (int i = 0; i < n; i++) printf("%d %u\n", i, h[i]);
  return 0;
}
