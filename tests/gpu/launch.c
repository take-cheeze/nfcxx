/* Loads a cubin with the CUDA runtime API, runs mul2 on 1000 ints, checks b[i] == 2*a[i]. */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s FILE.cubin\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  fclose(f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }

  cudaLibrary_t lib;
  cudaKernel_t kernel;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  CK(cudaLibraryGetKernel(&kernel, lib, "mul2"));

  enum { N = 1000, GUARD = 64 };  /* GUARD zeroed ints past b: a missing bounds check writes there */
  int h[N + GUARD], o[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) h[i] = i - 300 + 1; /* nonzero tail: a stray store shows up */
  int *a, *b;
  CK(cudaMalloc((void **)&a, sizeof h));
  CK(cudaMalloc((void **)&b, sizeof o));
  CK(cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice));  /* N + GUARD ints: the tail is what a missing check would read */
  CK(cudaMemset(b, 0, sizeof o));                          /* all of o, guard included */

  int n = N;
  void *args[] = { &a, &b, &n };
  /* 8 blocks of 128 threads: 1024 threads for 1000 elements, so the bounds check is exercised. */
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){8, 1, 1};
  cfg.blockDim = (dim3){128, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaGetLastError());
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost));

  int bad = 0, stray = 0;
  for (int i = 0; i < N; i++) bad += o[i] != 2 * h[i];
  for (int i = N; i < N + GUARD; i++) stray += o[i] != 0;
  printf("mul2: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
  CK(cudaFree(a));
  CK(cudaFree(b));
  CK(cudaLibraryUnload(lib));
  return bad != 0 || stray != 0;
}
