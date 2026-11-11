// The lanes of nv_bfloat162 and half2, as llama.cpp's mmvf and mma.cuh use them: a bf16 lane in float arithmetic
// (ggml_cuda_mad(sum, x2.x, y.x)) converts the value, and a pair is 4-byte aligned, so reading one as an int (mma.cuh's
// `*((const int *) &x)`) is an aligned 32-bit load. Both pairs were `{ unsigned short x, y; }` with 2-byte alignment:
// the lanes converted as integers, and the int read after a half member faulted with "misaligned address".
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <stdio.h>
#include <string.h>

struct after_half {
  half a;
  half2 b;  // at offset 4, as in CUDA
};

__device__ void mad(float &acc, const float v, const float u) { acc += v * u; }  // ggml_cuda_mad's float form

__global__ void kern(const float *in, float *out, int *bits, int *align) {
  const int i = threadIdx.x;
  nv_bfloat162 b = __float22bfloat162_rn(make_float2(in[i], 2.0f * in[i]));
  float sum = 0.0f;
  mad(sum, b.x, 3.0f);  // a lane passed as a float, as mmvf does
  sum += (float)b.y;
  out[i] = sum;
  after_half s;
  s.a = __float2half(1.0f);
  s.b = make_half2(in[i], -in[i]);
  bits[i] = *((const int *)&s.b);
  if (i == 0) {
    align[0] = (int)alignof(half2);
    align[1] = (int)alignof(nv_bfloat162);
    align[2] = (int)((const char *)&s.b - (const char *)&s);
  }
}

int main() {
  const int n = 8;
  float h[n];
  for (int i = 0; i < n; i++) h[i] = 0.5f * i - 1.0f;  // exact in bf16 and in half
  float *din, *dout; int *dbits, *dal;
  cudaMalloc(&din, sizeof h); cudaMalloc(&dout, sizeof h); cudaMalloc(&dbits, n * sizeof(int)); cudaMalloc(&dal, 3 * sizeof(int));
  cudaMemcpy(din, h, sizeof h, cudaMemcpyHostToDevice);
  kern<<<1, n>>>(din, dout, dbits, dal);
  float out[n]; int bits[n], al[3];
  cudaMemcpy(out, dout, sizeof out, cudaMemcpyDeviceToHost);
  cudaMemcpy(bits, dbits, sizeof bits, cudaMemcpyDeviceToHost);
  cudaMemcpy(al, dal, sizeof al, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    bad += out[i] != 3.0f * h[i] + 2.0f * h[i];
    __half lo = __float2half(h[i]), hi = __float2half(-h[i]);
    unsigned short l, u;
    memcpy(&l, &lo, 2); memcpy(&u, &hi, 2);
    bad += (unsigned)bits[i] != ((unsigned)u << 16 | l);
  }
  bad += al[0] != 4;
  bad += al[1] != 4;
  bad += al[2] != 4;
  printf("pair lanes: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
