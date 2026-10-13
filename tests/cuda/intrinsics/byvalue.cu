// A struct passed and returned by value in device code (byval and sret: the device passes the address), against the
// host. Each thread builds a two-field struct, returns it from a helper, passes it to another helper by value, and
// writes both fields. Exact.
#include <cuda_runtime.h>
#include <stdio.h>

struct Pair { unsigned short x, y; };

__device__ Pair make_pair(unsigned v) {
  Pair p;
  p.x = (unsigned short)(v * 3u);
  p.y = (unsigned short)(v + 7u);
  return p;
}

__device__ unsigned combine(Pair p) { return (unsigned)p.x * 65536u + p.y; }

__global__ void kpair(unsigned *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  Pair p = make_pair((unsigned)i);
  out[2 * i] = combine(p);
  out[2 * i + 1] = (unsigned)p.x + p.y;
}

int main() {
  const int n = 256;
  unsigned h[2 * n];
  unsigned *d;
  cudaMalloc((void **)&d, sizeof h);
  kpair<<<(n + 63) / 64, 64>>>(d, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    unsigned x = (unsigned short)((unsigned)i * 3u), y = (unsigned short)((unsigned)i + 7u);
    bad += h[2 * i] != x * 65536u + y || h[2 * i + 1] != x + y;
  }
  printf("byvalue: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
