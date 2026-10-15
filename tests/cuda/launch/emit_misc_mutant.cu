// Emitter lowerings for bool kernel parameters, bool arguments of device functions, bool-to-float conversion and
// volatile store and load (the statements that mmid, pad, diagmask and allreduce need). Each result is exact.
#include <cuda_runtime.h>
#include <stdio.h>

__device__ int pick(bool b, int x) { return !b ? x : 0; }

__global__ void kern(bool flag, int *out, float *fout, volatile int *vs, int *out2) {
  int i = threadIdx.x;
  out[i] = pick(flag, i) + 1000 * (int)flag;   // bool kernel parameter and bool device-function argument
  fout[i] = (float)flag * 10.0f + (float)i;    // bool to float
  vs[i] = i * 3;                               // volatile store
  out2[i] = vs[i] + 1;                         // volatile load of the same location
}

static int run(bool flag, int *ref_out, float *ref_fout, int *ref_out2) {
  const int n = 8;
  int *out, *out2; float *fout; int *vs;
  cudaMalloc(&out, n * sizeof(int)); cudaMalloc(&out2, n * sizeof(int));
  cudaMalloc(&fout, n * sizeof(float)); cudaMalloc(&vs, n * sizeof(int));
  kern<<<1, n>>>(flag, out, fout, vs, out2);
  int h[8], h2[8]; float hf[8];
  cudaMemcpy(h, out, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(hf, fout, n * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(h2, out2, n * sizeof(int), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    bad += h[i] != ref_out[i];
    bad += hf[i] != ref_fout[i];
    bad += h2[i] != ref_out2[i];
  }
  cudaFree(out); cudaFree(out2); cudaFree(fout); cudaFree(vs);
  return bad;
}

int main() {
  const int n = 8;
  int r_out[8], r_out2[8]; float r_fout[8];
  int bad = 0;
  for (int i = 0; i < n; i++) { r_out2[i] = 3 * i + 1; }
  // flag = true: out = i + 1000, fout = 10 + i
  for (int i = 0; i < n; i++) { r_out[i] = i + 1000; r_fout[i] = 10.0f + (float)i; }
  bad += run(true, r_out, r_fout, r_out2);
  // flag = false: out = 0, fout = i
  for (int i = 0; i < n; i++) { r_out[i] = 0; r_fout[i] = (float)i; }
  bad += run(false, r_out, r_fout, r_out2);
  printf("emit misc: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
