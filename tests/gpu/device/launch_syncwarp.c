/* Runs warp_pass (syncwarp.cpp, lowered to PTX): each lane writes its index to the block's shared array, the warp
   barrier, then reads its neighbour's value. Four blocks of 32 threads; the expected result is out[g] = (t + 1) % 32
   for lane t = g % 32 of every block. */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

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

  enum { BLOCKS = 4, THREADS = 32, N = BLOCKS * THREADS };
  float h[N];
  float *d;
  CK(cudaMalloc((void **)&d, sizeof h));
  CK(cudaMemset(d, 0, sizeof h));
  void *args[] = { &d };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){BLOCKS, 1, 1};
  cfg.blockDim = (dim3){THREADS, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost));
  int bad = 0;
  for (int g = 0; g < N; g++) bad += h[g] != (float)((g % THREADS + 1) % THREADS);
  printf("syncwarp: %d lanes, %d mismatches\n", N, bad);
  CK(cudaFree(d));
  return bad != 0;
}
