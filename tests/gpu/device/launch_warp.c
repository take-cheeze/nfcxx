/* Runs warp_ops (warp.cpp, lowered to PTX) on 1000 elements, 128 threads per block (4 full warps). The expected values
   come from the definitions: a warp sum of the inputs (zero past n), the float shuffle from lane i^1, the ballot of
   lanes with v > 3, and any / all over the warp. */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

enum { N = 1000, GUARD = 64, BLOCKS = 8, THREADS = 128 };

static int v_of(const int *in, int j) { return j < N ? in[j] : 0; }

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

  static int in[N + GUARD], sum[N + GUARD], flags[N + GUARD];
  static float fswap[N + GUARD];
  static unsigned ballot[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) in[i] = i % 7 - 2;   /* negative values too */
  int *din, *dsum, *dflags; float *dfswap; unsigned *dballot;
  CK(cudaMalloc((void **)&din, sizeof in));
  CK(cudaMalloc((void **)&dsum, sizeof sum));
  CK(cudaMalloc((void **)&dfswap, sizeof fswap));
  CK(cudaMalloc((void **)&dballot, sizeof ballot));
  CK(cudaMalloc((void **)&dflags, sizeof flags));
  CK(cudaMemcpy(din, in, sizeof in, cudaMemcpyHostToDevice));
  CK(cudaMemset(dsum, 0, sizeof sum));
  CK(cudaMemset(dfswap, 0, sizeof fswap));
  CK(cudaMemset(dballot, 0, sizeof ballot));
  CK(cudaMemset(dflags, 0, sizeof flags));

  int n = N;
  void *args[] = { &din, &dsum, &dfswap, &dballot, &dflags, &n };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){BLOCKS, 1, 1};
  cfg.blockDim = (dim3){THREADS, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kernel, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(sum, dsum, sizeof sum, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(fswap, dfswap, sizeof fswap, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(ballot, dballot, sizeof ballot, cudaMemcpyDeviceToHost));
  CK(cudaMemcpy(flags, dflags, sizeof flags, cudaMemcpyDeviceToHost));

  int bad_sum = 0, bad_fswap = 0, bad_ballot = 0, bad_flags = 0;
  for (int i = 0; i < N; i++) {
    int w0 = i & ~31;
    int s = 0;
    unsigned b = 0;
    int any = 0, all = 1;
    for (int l = 0; l < 32; l++) {
      int v = v_of(in, w0 + l);
      s += v;
      int big = v > 3;
      if (big) b |= 1u << l;
      any |= big;
      all &= big;
    }
    bad_sum += sum[i] != s;
    bad_fswap += fswap[i] != (float)v_of(in, i ^ 1);
    bad_ballot += ballot[i] != b;
    bad_flags += flags[i] != (any | (all << 1));
  }
  printf("warp: %d elements: sum %d, shfl.f %d, ballot %d, any/all %d mismatches\n",
         N, bad_sum, bad_fswap, bad_ballot, bad_flags);
  CK(cudaFree(din)); CK(cudaFree(dsum)); CK(cudaFree(dfswap)); CK(cudaFree(dballot)); CK(cudaFree(dflags));
  CK(cudaLibraryUnload(lib));
  return bad_sum || bad_fswap || bad_ballot || bad_flags;
}
