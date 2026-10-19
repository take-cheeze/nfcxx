// A call that leaves out a function parameter with a default value (scale_rows_cuda's s) is a call of the template with
// its default, so the launch inside it gets the instance that the default gives (do_scale = false). Each result is
// checked exactly against the host.
#include <cuda_runtime.h>
#include <stdio.h>

template <bool do_scale>
static __global__ void scale_rows(float *x, float s) {
  int i = threadIdx.x;
  x[i] = do_scale ? x[i] * s : x[i];
}

template <bool do_scale = false>
static void scale_rows_cuda(float *x, int cnt, cudaStream_t stream, float s = 1.0f) {
  scale_rows<do_scale><<<1, cnt, 0, stream>>>(x, s);
}

int main() {
  const int N = 8;
  float h[N], want[N], *d;
  for (int i = 0; i < N; i++) h[i] = (float)(i + 1);
  cudaMalloc(&d, N * sizeof(float));
  cudaMemcpy(d, h, N * sizeof(float), cudaMemcpyHostToDevice);
  // scale_rows_cuda leaves out s (1.0) and do_scale (false): unchanged.
  scale_rows_cuda(d, N, 0);
  // scale_rows_cuda<true> leaves out nothing: 3x.
  scale_rows_cuda<true>(d, N, 0, 3.0f);
  cudaDeviceSynchronize();
  float got[N];
  cudaMemcpy(got, d, N * sizeof(float), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < N; i++) {
    want[i] = h[i] * 3.0f;
    if (got[i] != want[i]) bad++;
  }
  printf("default fn arg: %s\n", bad == 0 ? "exact" : "mismatch");
  cudaFree(d);
  return bad != 0;
}
