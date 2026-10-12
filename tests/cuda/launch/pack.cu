// A launch inside a parameter-pack template: run<Ns...> launches kpack<Ns...>, one instance per explicit call of run
// (here run<1, 2, 3> and run<7>). Each instance sums its pack: the output is exact.
#include <cuda_runtime.h>
#include <stdio.h>

template <int... Ns>
__global__ void kpack(int *p) {
  int s = 0;
  ((s += Ns), ...);
  p[threadIdx.x] = s + (int)threadIdx.x;
}

template <int... Ns>
static void run(int *p) {
  kpack<Ns...><<<1, 32>>>(p);
}

int main() {
  int *d1, *d2;
  cudaMalloc((void **)&d1, 32 * sizeof(int));
  cudaMalloc((void **)&d2, 32 * sizeof(int));
  run<1, 2, 3>(d1);
  run<7>(d2);
  int h1[32], h2[32];
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h1, d1, sizeof h1, cudaMemcpyDeviceToHost);
  cudaMemcpy(h2, d2, sizeof h2, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < 32; t++) bad += h1[t] != 6 + t || h2[t] != 7 + t;
  printf("pack: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
