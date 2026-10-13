// cublasSgemm on a 16x16 matrix pair, checked against a host product. Expect "cublas: 0 mismatches".
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <stdio.h>

int main() {
  const int n = 16;
  float a[n * n], b[n * n], c[n * n], ref[n * n];
  for (int i = 0; i < n * n; i++) {
    a[i] = (float)((i * 7) % 11) - 5.0f;
    b[i] = (float)((i * 5) % 13) - 6.0f;
  }
  for (int i = 0; i < n; i++)
    for (int j = 0; j < n; j++) {
      float s = 0;
      for (int k = 0; k < n; k++) s += a[i + k * n] * b[k + j * n];  // column-major
      ref[i + j * n] = s;
    }
  float *da, *db, *dc;
  cudaMalloc((void **)&da, sizeof a);
  cudaMalloc((void **)&db, sizeof b);
  cudaMalloc((void **)&dc, sizeof c);
  cudaMemcpy(da, a, sizeof a, cudaMemcpyHostToDevice);
  cudaMemcpy(db, b, sizeof b, cudaMemcpyHostToDevice);
  cublasHandle_t h;
  cublasCreate(&h);
  const float one = 1.0f, zero = 0.0f;
  cublasStatus_t st = cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &one, da, n, db, n, &zero, dc, n);
  cudaMemcpy(c, dc, sizeof c, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n * n; i++) bad += c[i] != ref[i];
  printf("cublas: status %d, %d mismatches\n", (int)st, bad);
  cublasDestroy(h);
  cudaFree(da);
  cudaFree(db);
  cudaFree(dc);
  return bad != 0 || st != CUBLAS_STATUS_SUCCESS;
}
