// isinf on float and double (the device prelude's bit tests) against the host's isinf, and __builtin_assume as a hint:
// its expression is not evaluated, so a side effect in it must not happen (the counter stays 0).
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>

__global__ void k(int *f_out, int *d_out, const float *f, const double *d, int *side, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __builtin_assume(atomicAdd(side, 1) >= 0);
  __builtin_assume(i < n);
  f_out[i] = isinf(f[i]);
  d_out[i] = isinf(d[i]);
}

int main() {
  const int n = 8;
  float F[n] = {INFINITY, -INFINITY, NAN, 1.0f, -2.5f, 0.0f, 1e-45f, 3.0e38f};
  double D[n] = {(double)INFINITY, -(double)INFINITY, (double)NAN, 1.0, -2.5, 0.0, 4.9e-324, 1.0e308};
  int wf[n], wd[n];
  for (int i = 0; i < n; i++) {
    wf[i] = (isinf(F[i]) != 0) || isnan(F[i]);
    wd[i] = isinf(D[i]) != 0;
  }
  float *df; double *dd; int *of, *od, *side;
  cudaMalloc((void **)&df, sizeof F); cudaMalloc((void **)&dd, sizeof D);
  cudaMalloc((void **)&of, sizeof wf); cudaMalloc((void **)&od, sizeof wd); cudaMalloc((void **)&side, sizeof(int));
  cudaMemcpy(df, F, sizeof F, cudaMemcpyHostToDevice);
  cudaMemcpy(dd, D, sizeof D, cudaMemcpyHostToDevice);
  cudaMemset(side, 0, sizeof(int));
  k<<<1, n>>>(of, od, df, dd, side, n);
  cudaError_t err = cudaDeviceSynchronize();
  int hf[n], hd[n], hs = 0;
  cudaMemcpy(hf, of, sizeof hf, cudaMemcpyDeviceToHost);
  cudaMemcpy(hd, od, sizeof hd, cudaMemcpyDeviceToHost);
  cudaMemcpy(&hs, side, sizeof hs, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += (hf[i] != 0) != (wf[i] != 0) || (hd[i] != 0) != (wd[i] != 0);
  bad += hs != 0;
  printf("isinf: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
