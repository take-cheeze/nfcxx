// Block and system intrinsics of ggml-cuda: __syncthreads_or, __reduce_add_sync, __threadfence_system, __nanosleep,
// __isnanf and __shfl_up_sync, each checked on the GPU against the value CUDA defines (exact).
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>

__global__ void k_or(int *out, int sel) {
  int i = threadIdx.x;
  out[blockIdx.x * blockDim.x + i] = __syncthreads_or(i == sel);
}

__global__ void k_red(unsigned *out) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  out[i] = __reduce_add_sync(0xffffffffu, (threadIdx.x % 32) + 1u);
}

__global__ void k_fence(int *out) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  out[i] = 2 * i;
  __threadfence_system();
  __nanosleep(10);
  out[i] += 1;
}

__global__ void k_nan(int *out, const float *x, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = __isnanf(x[i]);
}

__global__ void k_shfl(float *out) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  out[i] = __shfl_up_sync(0xffffffffu, (float)(threadIdx.x % 32), 1);
}

int main() {
  int bad = 0;
  const int blocks = 4, threads = 64, n = blocks * threads;
  int *di, hi[n];
  unsigned *du, hu[n];
  float *df, hf[n];
  cudaMalloc((void **)&di, sizeof hi);
  cudaMalloc((void **)&du, sizeof hu);

  k_or<<<blocks, threads>>>(di, threads - 1);
  cudaMemcpy(hi, di, sizeof hi, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += hi[i] != 1;
  k_or<<<blocks, threads>>>(di, 1000);
  cudaMemcpy(hi, di, sizeof hi, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += hi[i] != 0;

  k_red<<<blocks, threads>>>(du);
  cudaMemcpy(hu, du, sizeof hu, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += hu[i] != 528u;

  k_fence<<<blocks, threads>>>(di);
  cudaMemcpy(hi, di, sizeof hi, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += hi[i] != 2 * i + 1;

  float nanv = NAN;
  float xs[4] = {nanv, 1.0f, INFINITY, -0.0f};
  float *dx;
  int hn[4];
  cudaMalloc((void **)&dx, sizeof xs);
  cudaMemcpy(dx, xs, sizeof xs, cudaMemcpyHostToDevice);
  k_nan<<<1, 4>>>(di, dx, 4);
  cudaMemcpy(hn, di, sizeof hn, cudaMemcpyDeviceToHost);
  int want_nan[4] = {1, 0, 0, 0};
  for (int i = 0; i < 4; i++) bad += hn[i] != want_nan[i];

  float *dsh, hsh[n];
  cudaMalloc((void **)&dsh, sizeof hsh);
  k_shfl<<<blocks, threads>>>(dsh);
  cudaMemcpy(hsh, dsh, sizeof hsh, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) {
    int lane = i % 32;
    bad += hsh[i] != (float)(lane == 0 ? 0 : lane - 1);
  }
  cudaError_t err = cudaDeviceSynchronize();
  printf("block: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
