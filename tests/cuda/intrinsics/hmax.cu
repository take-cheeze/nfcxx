// __hmax on 16-bit half values (the device prelude's half is an unsigned short), against CUDA's host conversions
// (cuda_fp16.h): the non-NaN operand wins, as fmax does; NaN with NaN stays NaN.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <math.h>
#include <stdio.h>

__global__ void k(unsigned short *out, const unsigned short *a, const unsigned short *b, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = __hmax(a[i], b[i]);
}

int main() {
  const int n = 8;
  float A[n] = {1.5f, -3.0f, NAN, 4.0f, NAN, -8.0f, 2.0f, 0.0f};
  float B[n] = {2.5f, -1.0f, 4.0f, NAN, -5.0f, NAN, 2.0f, -0.0f};
  float W[n] = {2.5f, -1.0f, 4.0f, 4.0f, -5.0f, -8.0f, 2.0f, 0.0f};
  unsigned short ha[n], hb[n], hr[n], want[n];
  for (int i = 0; i < n; i++) {
    ha[i] = __half_as_ushort(__float2half(A[i]));
    hb[i] = __half_as_ushort(__float2half(B[i]));
    want[i] = __half_as_ushort(__float2half(W[i]));
  }
  unsigned short *da, *db, *dr;
  cudaMalloc((void **)&da, sizeof ha);
  cudaMalloc((void **)&db, sizeof hb);
  cudaMalloc((void **)&dr, sizeof hr);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice);
  cudaMemcpy(db, hb, sizeof hb, cudaMemcpyHostToDevice);
  k<<<1, n>>>(dr, da, db, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hr, dr, sizeof hr, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += hr[i] != want[i];
  printf("hmax: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
