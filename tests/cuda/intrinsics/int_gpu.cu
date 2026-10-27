// Integer division by zero, INT_MIN / -1 and shift counts of the width or more in device code (the driver passes
// pathb-ptx-emit --int=gpu): what the GPU does, as nvcc emits it, not a trap. The quotients are unspecified, so only
// the absence of an error is checked for them; a shift count is clamped to the width (PTX shl/shr), so x << 40 is 0
// and a signed x >> 40 is the sign. llama.cpp's flash_attn_ext_vec computes `sequence % ne33` with ne33 == 0.
#include <cuda_runtime.h>
#include <limits.h>
#include <stdio.h>

__global__ void k(int *o, int zero, int minus1, int big, int x) {
  volatile int q = x / zero, r = x % zero, m = INT_MIN / minus1;
  (void)q; (void)r; (void)m;
  o[0] = x << big;
  o[1] = (-8) >> big;
  o[2] = (int)((unsigned)x >> big);
  o[3] = x / 3 + x % 3;  // a defined division still divides
}

int main() {
  int *d, h[4];
  cudaMalloc(&d, sizeof h);
  k<<<1, 1>>>(d, 0, -1, 40, 1000);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = (h[0] != 0) + (h[1] != -1) + (h[2] != 0) + (h[3] != 1000 / 3 + 1000 % 3);
  printf("int_gpu: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return err != cudaSuccess || bad != 0;
}
