// A device-only #if on a -D define: the device pass must see the define the host compile gets (-DFEATURE_X=1).
// The expected value is fixed (7), so a device unit that drops the define writes 3 and the check sees mismatches.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void pick(int *out) {
#if FEATURE_X
  out[threadIdx.x] = 7;
#else
  out[threadIdx.x] = 3;
#endif
}

int main() {
  int *d = nullptr, h[32];
  cudaMalloc(&d, sizeof h);
  pick<<<1, 32>>>(d);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 32; i++)
    if (h[i] != 7) bad++;
  printf("device define: %d mismatches\n", bad);
  return bad != 0;
}
