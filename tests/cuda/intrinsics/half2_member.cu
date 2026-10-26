// __half2 members (.x and .y, read and written through a variable) and the float2 conversions of ggml-cuda, from device
// code, against the host. Halves are given as bit patterns; the results are exact.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>

__global__ void khalf2(float *out, unsigned short a, unsigned short b, unsigned short c, unsigned short d) {
  __half2 h = __halves2half2(__ushort_as_half(a), __ushort_as_half(b));
  float lo = __low2float(h), hi = __high2float(h);
  float2 f = __half22float2(h);
  out[0] = lo;
  out[1] = hi;
  out[2] = f.x;
  out[3] = f.y;
  h.y = __ushort_as_half(c);   /* a member write */
  h.x = __ushort_as_half(d);
  out[4] = __low2float(h);
  out[5] = __high2float(h);   /* the member write is seen through __high2float */
  __half2 g = __float22half2_rn(make_float2(1.0f, -2.0f));
  out[6] = __high2float(g);
  out[7] = __low2float(g);
}

int main() {
  float *d, h[8];
  cudaMalloc((void **)&d, sizeof h);
  khalf2<<<1, 1>>>(d, 0x3C00, 0x4000, 0xC000, 0x4400);   /* 1.0, 2.0, -2.0, 4.0 */
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  const float want[8] = {1.0f, 2.0f, 1.0f, 2.0f, 4.0f, -2.0f, -2.0f, 1.0f};
  int bad = 0;
  for (int i = 0; i < 8; i++) bad += h[i] != want[i];
  printf("half2 member: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
