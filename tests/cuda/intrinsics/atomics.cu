// The atomics llama.cpp's ggml-cuda uses, through the device prelude (BUILTIN_DEFS) and the emitter's ATOMICS table:
// atomicAdd (int, unsigned, float), atomicMax (int) and atomicCAS (int), exactly against the host.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void katomic(int *cnt, unsigned *usum, float *fsum, int *mx, int *cas, int *seen, int *flags, int *single, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int old = atomicAdd(cnt, 1);
  seen[i] = old;
  flags[old] = 1;
  atomicAdd(usum, (unsigned)i);
  atomicAdd(fsum, 1.0f);
  atomicMax(mx, i);
  int c = *cas, want;
  do {
    want = c;
    c = atomicCAS(cas, want, want + 1);
  } while (c != want);
}

// One thread, its own launch: the adds run in order, so each returns the count it was.
__global__ void ksingle(int *cnt, int *single) {
  for (int k = 0; k < 16; k++) single[k] = atomicAdd(cnt, 1);
}

int main() {
  const int n = 4096;
  int *dcnt, *dmx, *dcas, *dseen, *dflags, *dsingle;
  unsigned *dusum;
  float *dfsum;
  cudaMalloc((void **)&dcnt, sizeof(int)); cudaMalloc((void **)&dmx, sizeof(int)); cudaMalloc((void **)&dcas, sizeof(int));
  cudaMalloc((void **)&dseen, n * sizeof(int)); cudaMalloc((void **)&dflags, n * sizeof(int));
  cudaMalloc((void **)&dsingle, 16 * sizeof(int));
  cudaMalloc((void **)&dusum, sizeof(unsigned)); cudaMalloc((void **)&dfsum, sizeof(float));
  int zero = 0, lowest = -2147483647 - 1;
  cudaMemset(dcnt, 0, sizeof(int)); cudaMemset(dusum, 0, sizeof(unsigned)); cudaMemset(dfsum, 0, sizeof(float));
  cudaMemset(dcas, 0, sizeof(int)); cudaMemset(dflags, 0, n * sizeof(int));
  cudaMemcpy(dmx, &lowest, sizeof(int), cudaMemcpyHostToDevice);
  katomic<<<(n + 127) / 128, 128>>>(dcnt, dusum, dfsum, dmx, dcas, dseen, dflags, dsingle, n);
  ksingle<<<1, 1>>>(dcnt, dsingle);
  cudaError_t err = cudaDeviceSynchronize();
  int cnt, mx, cas, seen[n], flags[n], single[16];
  unsigned usum; float fsum;
  cudaMemcpy(&cnt, dcnt, sizeof cnt, cudaMemcpyDeviceToHost);
  cudaMemcpy(&usum, dusum, sizeof usum, cudaMemcpyDeviceToHost);
  cudaMemcpy(&fsum, dfsum, sizeof fsum, cudaMemcpyDeviceToHost);
  cudaMemcpy(&mx, dmx, sizeof mx, cudaMemcpyDeviceToHost);
  cudaMemcpy(&cas, dcas, sizeof cas, cudaMemcpyDeviceToHost);
  cudaMemcpy(seen, dseen, sizeof seen, cudaMemcpyDeviceToHost);
  cudaMemcpy(flags, dflags, sizeof flags, cudaMemcpyDeviceToHost);
  cudaMemcpy(single, dsingle, sizeof single, cudaMemcpyDeviceToHost);
  int bad = 0;
  // n adds, plus the 16 of the single-thread loop
  bad += cnt != n + 16;
  bad += usum != (unsigned)n * (n - 1) / 2;
  bad += fsum != (float)n;
  bad += mx != n - 1;
  bad += cas != n;
  // each add of the first pass returned a distinct old value in [0, n): the flags are all set exactly once
  for (int k = 0; k < n; k++) bad += flags[k] != 1;
  // the single thread's adds, in their own launch after the others, return n, n+1, ... in order
  for (int k = 0; k < 16; k++) bad += single[k] != n + k;
  printf("atomics: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
