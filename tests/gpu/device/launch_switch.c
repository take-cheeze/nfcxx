/* Runs classify (switch.cpp, lowered to PTX) on 1000 ints: in[i] = i % 7. Checks every result against the C switch
   (case 1 falls through to case 2: 15; case 2: 5; case 3: 7; case 4: 100; default: -1) and a guard region. */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

static int expect(int x) {
  switch (x) {
    case 1: return 15;
    case 2: return 5;
    case 3: return 7;
    case 4: return 100;
    default: return -1;
  }
}

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

  enum { N = 1000, GUARD = 64 };
  static int h[N + GUARD], o[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) { h[i] = i % 7; o[i] = 12345; }
  int *a, *b;
  CK(cudaMalloc((void **)&a, sizeof h));
  CK(cudaMalloc((void **)&b, sizeof o));
  CK(cudaMemcpy(a, h, sizeof h, cudaMemcpyHostToDevice));
  CK(cudaMemcpy(b, o, sizeof o, cudaMemcpyHostToDevice));

  int n = N;
  void *args[] = { &a, &b, &n };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){8, 1, 1};
  cfg.blockDim = (dim3){128, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(o, b, sizeof o, cudaMemcpyDeviceToHost));

  int bad = 0, stray = 0;
  for (int i = 0; i < N; i++) bad += o[i] != expect(h[i]);
  for (int i = N; i < N + GUARD; i++) stray += o[i] != 12345;
  printf("switch: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
  return bad != 0 || stray != 0;
}
