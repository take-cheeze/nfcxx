// CUB's thread loads and stores (cub/thread/thread_load.cuh): inline PTX whose operands are 16-bit ("h"), 32-bit ("r")
// and 64-bit ("l") registers, with 64-bit pointers. Each form loads a value, stores it back, and the host checks the
// stored values exactly against the inputs.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void copy_widths(const unsigned short *src16, const unsigned *src32, const unsigned long long *src64,
                            unsigned short *dst16, unsigned *dst32, unsigned long long *dst64) {
#ifdef __CUDA_ARCH__
  unsigned short v16;
  unsigned v32;
  unsigned long long v64;
  asm volatile("ld.global.u16 %0, [%1];" : "=h"(v16) : "l"(src16));
  asm volatile("ld.global.u32 %0, [%1];" : "=r"(v32) : "l"(src32));
  asm volatile("ld.global.u64 %0, [%1];" : "=l"(v64) : "l"(src64));
  asm volatile("st.global.u16 [%0], %1;" : : "l"(dst16), "h"(v16));
  asm volatile("st.global.u32 [%0], %1;" : : "l"(dst32), "r"(v32));
  asm volatile("st.global.u64 [%0], %1;" : : "l"(dst64), "l"(v64));
#endif
}

int main() {
  const unsigned short in16 = 0xBEEFu;
  const unsigned in32 = 0xDEADBEEFu;
  const unsigned long long in64 = 0x0123456789ABCDEFull;
  unsigned short *s16, *d16;
  unsigned *s32, *d32;
  unsigned long long *s64, *d64;
  cudaMalloc((void **)&s16, sizeof in16);
  cudaMalloc((void **)&d16, sizeof in16);
  cudaMalloc((void **)&s32, sizeof in32);
  cudaMalloc((void **)&d32, sizeof in32);
  cudaMalloc((void **)&s64, sizeof in64);
  cudaMalloc((void **)&d64, sizeof in64);
  cudaMemcpy(s16, &in16, sizeof in16, cudaMemcpyHostToDevice);
  cudaMemcpy(s32, &in32, sizeof in32, cudaMemcpyHostToDevice);
  cudaMemcpy(s64, &in64, sizeof in64, cudaMemcpyHostToDevice);
  cudaMemset(d16, 0, sizeof in16);
  cudaMemset(d32, 0, sizeof in32);
  cudaMemset(d64, 0, sizeof in64);
  copy_widths<<<1, 1>>>(s16, s32, s64, d16, d32, d64);
  unsigned short o16 = 0;
  unsigned o32 = 0;
  unsigned long long o64 = 0;
  cudaMemcpy(&o16, d16, sizeof o16, cudaMemcpyDeviceToHost);
  cudaMemcpy(&o32, d32, sizeof o32, cudaMemcpyDeviceToHost);
  cudaMemcpy(&o64, d64, sizeof o64, cudaMemcpyDeviceToHost);
  int bad = 0;
  bad += o16 != in16;
  bad += o32 != in32;
  bad += o64 != in64;
  printf("ptx widths: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
