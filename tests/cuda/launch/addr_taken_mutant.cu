// Kernel instances whose addresses are taken: chosen by a ternary (non-dependent) and inside a template function
// (dependent on its parameter), then handed to a host function that launches them by address (fattn.cu's pattern).
#include <cuda_runtime.h>
#include <stdio.h>

template <int K> __global__ void addk(int *p, int v) { p[threadIdx.x] = v + K; }
template <int K> __global__ void mulk(int *p, int v) { p[threadIdx.x] = v * K; }

static int run(void (*k)(int *, int), int *dp, int v, int *expect) {
  void *args[] = {&dp, &v};
  if (cudaLaunchKernel(k, dim3(1), dim3(4), args, 0, 0) != cudaSuccess) return 1000;
  if (cudaDeviceSynchronize() != cudaSuccess) return 1000;
  int h[4];
  cudaMemcpy(h, dp, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 4; i++) bad += h[i] != expect[i];
  return bad;
}

template <int N> static int pick_run(int *dp, int v) {
  int expect[4];
  // dependent on N: the instance comes from the explicit calls of pick_run below (N = 1 and N = 4)
  auto k = N > 2 ? addk<N> : mulk<N>;
  for (int i = 0; i < 4; i++) expect[i] = N > 2 ? v + N : v * N;
  return run(k, dp, v, expect);
}

int main() {
  int *dp;
  cudaMalloc(&dp, 4 * sizeof(int));
  int bad = 0;
  // non-dependent: a ternary over two instances, then the chosen one is launched by address
  for (int c = 0; c < 2; c++) {
    auto k = c ? addk<3> : addk<3>;
    int expect[4];
    for (int i = 0; i < 4; i++) expect[i] = c ? 2 + 3 : 2 * 5;
    bad += run(k, dp, 2, expect);
  }
  bad += pick_run<1>(dp, 7);
  bad += pick_run<4>(dp, 7);
  printf("addr taken: %d mismatches\n", bad);
  cudaFree(dp);
  return bad != 0;
}
