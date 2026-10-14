// A host template whose instances come from calls without explicit template arguments (T is deduced from the
// argument types, as nvcc does), with a kernel template launched inside it (its T is the host template's T).
#include <cuda_runtime.h>
#include <stdio.h>

template <typename T> __global__ void kscale(const T *x, T *y, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) y[i] = x[i] * (T)2;
}

template <typename T> void run(const T *x, T *y, int n) {
  kscale<<<(n + 31) / 32, 32>>>(x, y, n);
}

int main() {
  const int n = 100;
  float hf[n], of[n]; int hi[n], oi[n];
  for (int i = 0; i < n; i++) { hf[i] = 0.5f * i; hi[i] = 3 * i - 7; }
  float *df, *dof; int *di, *doi;
  cudaMalloc((void **)&df, sizeof hf); cudaMalloc((void **)&dof, sizeof of);
  cudaMalloc((void **)&di, sizeof hi); cudaMalloc((void **)&doi, sizeof oi);
  cudaMemcpy(df, hf, sizeof hf, cudaMemcpyHostToDevice);
  cudaMemcpy(di, hi, sizeof hi, cudaMemcpyHostToDevice);
  run(df, dof, n);
  run(di, doi, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(of, dof, sizeof of, cudaMemcpyDeviceToHost);
  cudaMemcpy(oi, doi, sizeof oi, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    bad += of[i] != hf[i] * 2.0f;
    bad += oi[i] != hi[i] * 2;
  }
  printf("deduce: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
