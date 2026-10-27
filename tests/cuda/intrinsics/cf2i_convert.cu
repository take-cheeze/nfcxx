// Float to integer outside the target's range, as the GPU converts it (the driver's --f2i=convert): cvt.rzi saturates,
// NaN gives 0 up to 32 bits, and a 1- or 2-byte target converts to 32 bits and keeps the low bytes. nvcc emits the same,
// and CUDA code relies on it: llama.cpp's quantize_mmq_q8_1 rounds NaN into a char4 for an all-zero block. The C++ range
// check traps instead.
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>

__global__ void k(const float *in, int n, signed char *sc, unsigned char *uc, short *ss, unsigned short *us, int *si,
                  unsigned *ui, long long *sl, unsigned long long *ul) {
  int i = threadIdx.x;
  if (i >= n) return;
  float v = in[i];
  sc[i] = (signed char)v; uc[i] = (unsigned char)v; ss[i] = (short)v; us[i] = (unsigned short)v;
  si[i] = (int)v; ui[i] = (unsigned)v; sl[i] = (long long)v; ul[i] = (unsigned long long)v;
}

// The expected values are nvcc's (sm_75) for the same kernel: signed char, unsigned char, short, unsigned short, int,
// unsigned, long long, unsigned long long. NaN gives 0 up to 32 bits and 1 << 63 for both 64-bit types.
struct Row { long long sc, uc, ss, us, si, ui; long long sl; unsigned long long ul; };
static const Row expect[] = {
    {0, 0, 0, 0, 0, 0, (-9223372036854775807LL - 1), 9223372036854775808ULL},
    {-1, 255, -1, 65535, 2147483647, 4294967295, 9223372036854775807LL, 18446744073709551615ULL},
    {0, 0, 0, 0, -2147483648, 0, (-9223372036854775807LL - 1), 0ULL},
    {44, 44, 300, 300, 300, 300, 300LL, 300ULL},
    {-44, 0, -300, 0, -300, 0, -300LL, 0ULL},
    {112, 112, 4464, 4464, 70000, 70000, 70000LL, 70000ULL},
    {-112, 0, -4464, 0, -70000, 0, -70000LL, 0ULL},
    {-1, 0, -1, 24064, 2147483647, 3000000000, 3000000000LL, 3000000000ULL},
    {0, 0, 0, 0, -2147483648, 0, -3000000000LL, 0ULL},
    {-1, 255, -1, 65535, 2147483647, 4294967295, 9223372036854775807LL, 9999999980506447872ULL},
    {-1, 255, -1, 65535, 2147483647, 4294967295, 9223372036854775807LL, 18446744073709551615ULL},
    {-1, 0, -1, 0, -1, 0, -1LL, 0ULL},
    {127, 127, 127, 127, 127, 127, 127LL, 127ULL}};

int main() {
  const float in[] = {NAN, INFINITY, -INFINITY, 300.5f, -300.5f, 70000.0f, -70000.0f, 3e9f, -3e9f, 1e19f, 2e19f, -1.0f, 127.9f};
  const int n = sizeof in / sizeof in[0];
  float *din; cudaMalloc(&din, sizeof in); cudaMemcpy(din, in, sizeof in, cudaMemcpyHostToDevice);
  signed char *sc; unsigned char *uc; short *ss; unsigned short *us; int *si; unsigned *ui; long long *sl; unsigned long long *ul;
  cudaMalloc(&sc, 32); cudaMalloc(&uc, 32); cudaMalloc(&ss, 64); cudaMalloc(&us, 64);
  cudaMalloc(&si, 128); cudaMalloc(&ui, 128); cudaMalloc(&sl, 256); cudaMalloc(&ul, 256);
  k<<<1, 32>>>(din, n, sc, uc, ss, us, si, ui, sl, ul);
  cudaError_t err = cudaDeviceSynchronize();
  signed char hsc[32]; unsigned char huc[32]; short hss[32]; unsigned short hus[32]; int hsi[32]; unsigned hui[32];
  long long hsl[32]; unsigned long long hul[32];
  cudaMemcpy(hsc, sc, 32, cudaMemcpyDeviceToHost); cudaMemcpy(huc, uc, 32, cudaMemcpyDeviceToHost);
  cudaMemcpy(hss, ss, 64, cudaMemcpyDeviceToHost); cudaMemcpy(hus, us, 64, cudaMemcpyDeviceToHost);
  cudaMemcpy(hsi, si, 128, cudaMemcpyDeviceToHost); cudaMemcpy(hui, ui, 128, cudaMemcpyDeviceToHost);
  cudaMemcpy(hsl, sl, 256, cudaMemcpyDeviceToHost); cudaMemcpy(hul, ul, 256, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    const Row &e = expect[i];
    if (hsc[i] != e.sc || huc[i] != e.uc || hss[i] != e.ss || hus[i] != e.us || hsi[i] != e.si || hui[i] != e.ui ||
        hsl[i] != e.sl || hul[i] != e.ul) {
      printf("input %d: %d %u %d %u %d %u %lld %llu\n", i, hsc[i], huc[i], hss[i], hus[i], hsi[i], hui[i], hsl[i], hul[i]);
      bad++;
    }
  }
  printf("cf2i convert: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return err != cudaSuccess || bad != 0;
}
