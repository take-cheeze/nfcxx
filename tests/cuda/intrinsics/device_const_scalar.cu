// A __device__ const scalar with a literal initializer (upscale.cu's `__device__ const float a = -0.75f;`) is a device
// constant: device functions read it and the rewriter keeps it (it was refused as a device variable). Checked exactly.
#include <cuda_runtime.h>
#include <stdio.h>

namespace bicubic {
__device__ const float alpha = -0.75f;
__device__ const int shift = 3;
static __device__ float weight(float x) { return alpha * x + shift; }
}

__global__ void k(float *y) {
  int i = threadIdx.x;
  y[i] = bicubic::weight((float)i);
}

int main() {
  float *dy;
  cudaMalloc((void **)&dy, 32 * sizeof(float));
  k<<<1, 32>>>(dy);
  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("device const scalar: kernel error %s\n", cudaGetErrorString(err));
    return 1;
  }
  float out[32];
  cudaMemcpy(out, dy, sizeof out, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 32; i++) bad += out[i] != -0.75f * (float)i + 3.0f;
  printf("device const scalar: no error, %d mismatches\n", bad);
  return bad != 0;
}
