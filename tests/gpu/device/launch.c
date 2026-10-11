/* Runs the vecAdd device kernel (vecadd.cpp, lowered to PTX by scripts/pathb-ptx-emit.rb) on 50000 elements. */
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s FILE.cubin KERNEL\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }
  fclose(f);

  cudaLibrary_t lib;
  cudaKernel_t kernel;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  CK(cudaLibraryGetKernel(&kernel, lib, argv[2]));

  enum { N = 50000, GUARD = 64 };
  float *ha = malloc(sizeof(float) * (N + GUARD)), *hb = malloc(sizeof(float) * (N + GUARD));
  float *hc = malloc(sizeof(float) * (N + GUARD));
  for (int i = 0; i < N + GUARD; i++) { ha[i] = (float)i; hb[i] = 2.0f * (float)i; hc[i] = -1.0f; }
  float *a, *b, *c;
  CK(cudaMalloc((void **)&a, sizeof(float) * (N + GUARD)));
  CK(cudaMalloc((void **)&b, sizeof(float) * (N + GUARD)));
  CK(cudaMalloc((void **)&c, sizeof(float) * (N + GUARD)));
  CK(cudaMemcpy(a, ha, sizeof(float) * (N + GUARD), cudaMemcpyHostToDevice));
  CK(cudaMemcpy(b, hb, sizeof(float) * (N + GUARD), cudaMemcpyHostToDevice));
  CK(cudaMemcpy(c, hc, sizeof(float) * (N + GUARD), cudaMemcpyHostToDevice));

  int n = N;
  void *args[] = { &a, &b, &c, &n };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){(N + 255) / 256, 1, 1};
  cfg.blockDim = (dim3){256, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(hc, c, sizeof(float) * (N + GUARD), cudaMemcpyDeviceToHost));

  int bad = 0;
  for (int i = 0; i < N; i++) bad += hc[i] != 3.0f * (float)i;
  int stray = 0;
  for (int i = N; i < N + GUARD; i++) stray += hc[i] != -1.0f;
  printf("vecAdd: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
  return bad != 0 || stray != 0;
}
