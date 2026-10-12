/* Runs atomics (atomics.cpp, lowered to PTX) on 1000 elements, in[i] = i % 7 - 2. Checks the integer sum, the float
   sum (exact: the values are small integers), the max, the histogram by x & 7, and that exactly one thread wins the
   compare-and-swap (the cas word holds one of the inputs). */
#include <cuda_runtime.h>
#include <limits.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

enum { N = 1000, BLOCKS = 8, THREADS = 128, SENTINEL = -1000 };

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s FILE.cubin KERNEL\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  fclose(f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }

  cudaLibrary_t lib;
  cudaKernel_t kernel;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  CK(cudaLibraryGetKernel(&kernel, lib, argv[2]));

  static int in[N];
  for (int i = 0; i < N; i++) in[i] = i % 7 - 2;
  int total0 = 0, maxv0 = INT_MIN, bins0[8] = {0};
  float ftotal0 = 0.0f;
  for (int i = 0; i < N; i++) {
    total0 += in[i];
    ftotal0 += (float)in[i];
    if (in[i] > maxv0) maxv0 = in[i];
    bins0[in[i] & 7]++;
  }

  int *din, *dtotal, *dmax, *dbins, *dcas, *dwins; float *dftotal;
  CK(cudaMalloc((void **)&din, sizeof in));
  CK(cudaMalloc((void **)&dtotal, sizeof(int)));
  CK(cudaMalloc((void **)&dftotal, sizeof(float)));
  CK(cudaMalloc((void **)&dmax, sizeof(int)));
  CK(cudaMalloc((void **)&dbins, sizeof bins0));
  CK(cudaMalloc((void **)&dcas, sizeof(int)));
  CK(cudaMalloc((void **)&dwins, sizeof(int)));
  CK(cudaMemcpy(din, in, sizeof in, cudaMemcpyHostToDevice));
  CK(cudaMemset(dtotal, 0, sizeof(int)));
  CK(cudaMemset(dftotal, 0, sizeof(float)));
  int init_max = INT_MIN, init_cas = SENTINEL;
  CK(cudaMemcpy(dmax, &init_max, sizeof(int), cudaMemcpyHostToDevice));
  CK(cudaMemset(dbins, 0, sizeof bins0));
  CK(cudaMemcpy(dcas, &init_cas, sizeof(int), cudaMemcpyHostToDevice));
  CK(cudaMemset(dwins, 0, sizeof(int)));

  int n = N;
  void *args[] = { &din, &dtotal, &dftotal, &dmax, &dbins, &dcas, &dwins, &n };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){BLOCKS, 1, 1};
  cfg.blockDim = (dim3){THREADS, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());

  int total, maxv, bins[8], cas, wins; float ftotal;
  CK(cudaMemcpy(&total, dtotal, sizeof total, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(&ftotal, dftotal, sizeof ftotal, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(&maxv, dmax, sizeof maxv, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(bins, dbins, sizeof bins, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(&cas, dcas, sizeof cas, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(&wins, dwins, sizeof wins, cudaMemcpyDeviceToHost));

  int bad_bins = 0;
  for (int k = 0; k < 8; k++) bad_bins += bins[k] != bins0[k];
  int cas_is_input = 0;
  for (int i = 0; i < N; i++) cas_is_input |= cas == in[i];
  printf("atomics: total %s, float total %s, max %s, histogram %d mismatches, cas winners %d (%s)\n",
         total == total0 ? "ok" : "BAD", ftotal == ftotal0 ? "ok" : "BAD", maxv == maxv0 ? "ok" : "BAD",
         bad_bins, wins, cas_is_input ? "value is an input" : "BAD");
  int ok = total == total0 && ftotal == ftotal0 && maxv == maxv0 && bad_bins == 0 && wins == 1 && cas_is_input;
  CK(cudaFree(din)); CK(cudaFree(dtotal)); CK(cudaFree(dftotal)); CK(cudaFree(dmax));
  CK(cudaFree(dbins)); CK(cudaFree(dcas)); CK(cudaFree(dwins));
  CK(cudaLibraryUnload(lib));
  return ok ? 0 : 1;
}
