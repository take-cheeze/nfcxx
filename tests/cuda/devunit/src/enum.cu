// File-scope enums that device code uses (an anonymous one, and a named one), and a host-only enum that the device
// unit must not carry. The kernel writes both enums' values, and main checks them on the GPU.
#include <cuda_runtime.h>
#include <stdio.h>

enum { ANON_SCALE = 3, ANON_BIAS = 5 };
enum Named { NAMED_BASE = 100 };
enum HostOnly { HO_ONE = 7 };

__global__ void kenum(int *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = i * ANON_SCALE + ANON_BIAS + NAMED_BASE;
}

int main() {
  const int n = 256;
  int *d = 0, h[n];
  cudaMalloc((void **)&d, sizeof h);
  kenum<<<(n + 127) / 128, 128>>>(d, n);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += h[i] != i * 3 + 5 + 100;
  printf("enum: %d mismatches, host-only %d\n", bad, (int)HO_ONE);
  cudaFree(d);
  return bad != 0;
}
