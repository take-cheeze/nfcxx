/* Runs the block-reversal kernel (shared.cpp, lowered to PTX) on 4 blocks of 128 threads.
 * out[b*128 + t] must equal in[b*128 + 127 - t] for every element (0 mismatches). */
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

  enum { BLOCKS = 4, THREADS = 128, N = BLOCKS * THREADS };
  static float hin[N], hout[N];
  for (int i = 0; i < N; i++) hin[i] = 0.5f * (float)i + 1.0f;
  float *din, *dout;
  CK(cudaMalloc((void **)&din, sizeof hin));
  CK(cudaMalloc((void **)&dout, sizeof hout));
  CK(cudaMemcpy(din, hin, sizeof hin, cudaMemcpyHostToDevice));
  CK(cudaMemset(dout, 0, sizeof hout));

  void *args[] = { &din, &dout };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){BLOCKS, 1, 1};
  cfg.blockDim = (dim3){THREADS, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));

  int bad = 0;
  for (int b = 0; b < BLOCKS; b++)
    for (int t = 0; t < THREADS; t++)
      bad += hout[b * THREADS + t] != hin[b * THREADS + (THREADS - 1 - t)];
  printf("shared: %d elements, %d mismatches\n", N, bad);
  return bad != 0;
}
