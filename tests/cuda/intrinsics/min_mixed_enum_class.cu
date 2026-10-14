// min() of mixed integer types in device code (ggml-cuda's norm.cu: min(blockIdx.x * g + g, n) mixes unsigned and 64-bit
// types), and a scoped enum (`enum class`) named as a template argument of a kernel: its tag must be carried into the
// device unit. Results against the host's exact comparisons.
#include <cuda_runtime.h>
#include <stdio.h>

enum class mode { lo, hi };

template <mode M>
__global__ void k(long long *out, unsigned int u, long long s, unsigned long long w) {
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    out[0] = min(u, s);               // unsigned int vs long long
    out[1] = min(s, w);               // long long vs unsigned long long
    out[2] = min(u, (unsigned int)7); // same type
    out[3] = M == mode::hi ? 1 : 0;   // the scoped enum's enumerators
  }
}

int main() {
  const unsigned int u = 40000000000u % 4294967296u; // 2^32-residue, large enough to differ from s
  const long long s = -5;
  const unsigned long long w = 3;
  long long *d, h[4];
  cudaMalloc((void **)&d, sizeof h);
  k<mode::hi><<<1, 1>>>(d, u, s, w);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  long long want[4];
  want[0] = (long long)u < s ? (long long)u : s;
  want[1] = (unsigned long long)s < w ? (long long)(unsigned long long)s : (long long)w; // s converts to unsigned here
  want[2] = u < 7u ? (long long)u : 7;
  want[3] = 1;
  int bad = 0;
  for (int i = 0; i < 4; i++) bad += h[i] != want[i];
  printf("min mixed: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
