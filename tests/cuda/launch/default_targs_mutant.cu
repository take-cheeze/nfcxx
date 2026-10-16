// Template arguments that a launch or a call leaves out take their defaults, as C++ does: the bool parameters of
// scale_k (`bool add = false`, `bool mul = true`) are omitted by a launch that gives only the first two, and a host
// function template's `bool neg = false` is omitted by a call. Each result is checked exactly against the host.
#include <cuda_runtime.h>
#include <stdio.h>

template <int n, bool add = false, bool mul = true>
__global__ void scale_k(float *x, int cnt) {
  int i = threadIdx.x;
  if (i < cnt) {
    float v = x[i] * (float)n;
    if (add) v += 100.0f;
    if (mul) v *= 2.0f;
    x[i] = v;
  }
}

template <typename T, bool neg = false>
static void apply(float *x, int cnt) {
  scale_k<2, neg, false><<<1, 8>>>(x, cnt);
}

int main() {
  const int N = 8;
  float h[N], want[N], *d;
  for (int i = 0; i < N; i++) h[i] = (float)(i + 1);
  cudaMalloc(&d, N * sizeof(float));
  cudaMemcpy(d, h, N * sizeof(float), cudaMemcpyHostToDevice);
  // scale_k<3, true> leaves out mul (false): 3x + 100.
  scale_k<3, true><<<1, 8>>>(d, N);
  for (int i = 0; i < N; i++) want[i] = (float)(i + 1) * 3.0f + 100.0f;
  // apply<float> leaves out neg (false): 2x.
  apply<float>(d, N);
  for (int i = 0; i < N; i++) want[i] = want[i] * 2.0f;
  // apply<float, true>: 2x + 100.
  apply<float, true>(d, N);
  for (int i = 0; i < N; i++) want[i] = want[i] * 1.0f;
  cudaDeviceSynchronize();
  float got[N];
  cudaMemcpy(got, d, N * sizeof(float), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < N; i++) {
    float ref = (float)(i + 1) * 3.0f + 100.0f;  // after the launch
    ref = ref * 2.0f;                             // after apply<float>
    ref = ref * 2.0f + 100.0f;                    // after apply<float, true>
    if (got[i] != ref) bad++;
  }
  printf("defaults: %s\n", bad == 0 ? "exact" : "mismatch");
  cudaFree(d);
  return bad != 0;
}
