/* Runs the nonnull device kernel (nonnull.cpp, lowered to PTX) in two modes.
 *   ok:   a valid pointer; every out[i] must be *a + 1 (0 mismatches).
 *   null: a null pointer; the kernel must trap, so cudaDeviceSynchronize reports an error. */
#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

int main(int argc, char **argv) {
  if (argc != 4 || (strcmp(argv[3], "ok") && strcmp(argv[3], "null"))) {
    fprintf(stderr, "usage: %s FILE.cubin KERNEL ok|null\n", argv[0]);
    return 2;
  }
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

  enum { N = 1000, SLOTS = 1024 };  /* 8 blocks of 128 threads write every slot */
  int hin = 41, ho[SLOTS];
  int *a = NULL, *out = NULL;
  CK(cudaMalloc((void **)&out, sizeof(int) * SLOTS));
  CK(cudaMemset(out, 0, sizeof(int) * SLOTS));
  int nullmode = strcmp(argv[3], "null") == 0;
  if (!nullmode) {
    CK(cudaMalloc((void **)&a, sizeof(int)));
    CK(cudaMemcpy(a, &hin, sizeof hin, cudaMemcpyHostToDevice));
  }

  void *args[] = { &a, &out };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){(N + 127) / 128, 1, 1};
  cfg.blockDim = (dim3){128, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  cudaError_t sync = cudaDeviceSynchronize();

  if (nullmode) {
    if (sync == cudaSuccess) { printf("null: no trap\n"); return 1; }
    printf("null: trapped (%s)\n", cudaGetErrorString(sync));
    return 0;
  }
  if (sync != cudaSuccess) { fprintf(stderr, "sync: %s\n", cudaGetErrorString(sync)); return 1; }
  CK(cudaMemcpy(ho, out, sizeof ho, cudaMemcpyDeviceToHost));
  int bad = 0;
  for (int i = 0; i < N; i++) bad += ho[i] != hin + 1;
  printf("ok: %d elements, %d mismatches\n", N, bad);
  return bad != 0;
}
