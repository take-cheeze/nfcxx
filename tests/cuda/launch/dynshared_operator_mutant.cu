// A dynamic __shared__ array used as an operand of a multiplication (`s * meta[l].y`): the rewrite must keep it as the
// shared array, not read `s * meta[` as a pointer declaration. Integer data, so the result is exact.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void dyn_op(float *out, int n) {
  extern __shared__ float2 meta[];
  if (threadIdx.x == 0) {
    for (int l = 0; l < n; ++l) meta[l] = make_float2((float)(l + 1), (float)(l + 2));
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    float acc = 0.0f;
    for (int l = 0; l < n; ++l) {
      const float s = meta[l].x * 2.0f;
      acc += s * meta[l].x;
    }
    out[0] = acc;
  }
}

int main() {
  const int n = 8;
  float expect = 0.0f;
  for (int l = 0; l < n; ++l) expect += 2.0f * (float)(l + 1) * (float)(l + 2);
  float *d = nullptr, h = 0.0f;
  cudaMalloc(&d, sizeof(float));
  dyn_op<<<1, 32, n * sizeof(float2)>>>(d, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(&h, d, sizeof(float), cudaMemcpyDeviceToHost);
  cudaFree(d);
  int bad = (err != cudaSuccess || h != expect) ? 1 : 0;
  if (bad) printf("dynshared operator: %d mismatches (got %g, want %g)\n", bad, h, expect);
  else printf("dynshared operator: no error, 0 mismatches\n");
  return bad;
}
