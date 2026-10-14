// The half2 and bf16 forms that ggml-cuda uses beyond the pair functions of half2.cu: __low2float, __high2float,
// __hmax2 (the lane rule of __hmax: NaN loses, a zero tie gives +0 for mixed signs), and the bf16 conversions (round to
// nearest even, bit-exact). The host copy uses CUDA's types (cuda_fp16.h, cuda_bf16.h); the device uses the prelude's.
// Expected values are the bit patterns of CUDA's results for these inputs.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <stdio.h>
#include <string.h>

template <typename T> __host__ __device__ T as(unsigned v) { return *reinterpret_cast<const T *>(&v); }
template <typename T> __host__ __device__ unsigned bits(T v) { unsigned r = 0; memcpy(&r, &v, sizeof v); return r & 0xffffu; }

__global__ void k(const unsigned *h, const float *f, float *ff, unsigned *out) {
  auto hv = as<__half2>(h[0]);
  auto hw = as<__half2>(h[1]);
  ff[0] = __low2float(hv);
  ff[1] = __high2float(hv);
  auto mx = __hmax2(hv, hw);
  out[2] = *reinterpret_cast<unsigned *>(&mx);
  auto b0 = __float2bfloat16(f[0]);
  auto b1 = __float2bfloat16(f[1]);
  auto b2 = __float2bfloat16(f[2]);
  auto b3 = __float2bfloat16(f[3]);
  out[3] = bits(b0);
  out[4] = bits(b1);
  out[5] = bits(b2);
  out[6] = bits(b3);
  ff[2] = __bfloat162float(b0);
  auto bh = as<__nv_bfloat162>(h[0]);
  out[8] = bits(__low2bfloat16(bh));
  out[9] = bits(__high2bfloat16(bh));
}

int main() {
  // half pairs: x in the low 16 bits, y in the high: (1.0, -2.0) and (0.5, 3.0).
  unsigned h[2] = {0xc0003c00u, 0x42003800u};
  unsigned bitsf[4] = {0x3f808000u, 0x3f818000u, 0x40200000u, 0x7fc00001u};  // tie to even, tie up, 2.5, NaN
  float f[4];
  memcpy(f, bitsf, sizeof f);
  unsigned *dh, *dout; float *df, *dff;
  cudaMalloc((void **)&dh, sizeof h); cudaMalloc((void **)&dout, 10 * sizeof(unsigned));
  cudaMalloc((void **)&df, sizeof f); cudaMalloc((void **)&dff, 3 * sizeof(float));
  cudaMemcpy(dh, h, sizeof h, cudaMemcpyHostToDevice);
  cudaMemcpy(df, f, sizeof f, cudaMemcpyHostToDevice);
  k<<<1, 1>>>(dh, df, dff, dout);
  unsigned o[10];
  float ff[3];
  cudaMemcpy(o, dout, sizeof o, cudaMemcpyDeviceToHost);
  cudaMemcpy(ff, dff, sizeof ff, cudaMemcpyDeviceToHost);
  unsigned fb[3];
  memcpy(fb, ff, sizeof fb);
  // Expected: low2float = 1.0; high2float = -2.0; hmax2 lanes (max(1.0,0.5), max(-2.0,3.0)) = (1.0, 3.0), packed 0x42003c00;
  // bf16 of 0x3f808000 (tie, upper 0x3f80 even) = 0x3f80; 0x3f818000 (tie, upper odd) = 0x3f82; 2.5 = 0x4020; NaN keeps a NaN;
  // low2bfloat16 / high2bfloat16 of h[0] are its low and high 16 bits: 0x3c00 and 0xc000.
  int bad = 0;
  bad += fb[0] != 0x3f800000u;
  bad += fb[1] != 0xc0000000u;
  bad += o[2] != 0x42003c00u;
  bad += o[3] != 0x3f80u;
  bad += o[4] != 0x3f82u;
  bad += o[5] != 0x4020u;
  bad += (o[6] & 0x7fc0u) != 0x7fc0u;
  bad += fb[2] != 0x3f800000u;
  bad += o[8] != 0x3c00u;
  bad += o[9] != 0xc000u;
  printf("half2 forms: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
