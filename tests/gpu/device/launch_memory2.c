/* Runs the three kernels of memory2.cpp (lowered to PTX by tools/pathb-ptx-emit) and checks every result.
 * k_bool: 1000 elements, 8 blocks of 128; k_local_shared: 512 elements, 8 blocks of 64; k_global: one block of 256.
 * Each output has GUARD elements past its end, which must stay as they were written by the host. */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

enum { GUARD = 64 };

static int launch(cudaKernel_t k, dim3 grid, dim3 block, void **args) {
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = grid;
  cfg.blockDim = block;
  CK(cudaLaunchKernelExC(&cfg, (const void *)k, args));
  CK(cudaGetLastError());
  CK(cudaDeviceSynchronize());
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s FILE.cubin\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  fclose(f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }

  cudaLibrary_t lib;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  cudaKernel_t kb, ks, kg, ko;
  CK(cudaLibraryGetKernel(&kb, lib, "k_bool"));
  CK(cudaLibraryGetKernel(&ks, lib, "k_local_shared"));
  CK(cudaLibraryGetKernel(&kg, lib, "k_global"));
  CK(cudaLibraryGetKernel(&ko, lib, "k_offset"));

  int failures = 0;

  /* k_bool */
  {
    enum { N = 1000 };
    unsigned char hf[N + GUARD];
    int ho[N + GUARD];
    for (int i = 0; i < N + GUARD; i++) { hf[i] = 0xAA; ho[i] = -1; }
    unsigned char *df; int *dout;
    CK(cudaMalloc((void **)&df, sizeof hf));
    CK(cudaMalloc((void **)&dout, sizeof ho));
    CK(cudaMemcpy(df, hf, sizeof hf, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dout, ho, sizeof ho, cudaMemcpyHostToDevice));
    int n = N;
    void *args[] = { &df, &dout, &n };
    if (launch(kb, (dim3){8, 1, 1}, (dim3){128, 1, 1}, args)) return 1;
    CK(cudaMemcpy(hf, df, sizeof hf, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost));
    int bad = 0, stray = 0;
    for (int i = 0; i < N; i++) {
      int want_flag = (i % 3) == 0;
      bad += hf[i] != want_flag || ho[i] != (want_flag ? 8 : 3);
    }
    for (int i = N; i < N + GUARD; i++) stray += hf[i] != 0xAA || ho[i] != -1;
    printf("bool: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
    failures += bad != 0 || stray != 0;
    cudaFree(df);
    cudaFree(dout);
  }

  /* k_local_shared */
  {
    enum { N = 512 };
    int hin[N], hout[N + GUARD];
    for (int i = 0; i < N; i++) hin[i] = i * 5 + 1;
    for (int i = 0; i < N + GUARD; i++) hout[i] = -1;
    int *din, *dout;
    CK(cudaMalloc((void **)&din, sizeof hin));
    CK(cudaMalloc((void **)&dout, sizeof hout));
    CK(cudaMemcpy(din, hin, sizeof hin, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dout, hout, sizeof hout, cudaMemcpyHostToDevice));
    void *args[] = { &dout, &din };
    if (launch(ks, (dim3){8, 1, 1}, (dim3){64, 1, 1}, args)) return 1;
    CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));
    int bad = 0, stray = 0;
    for (int g = 0; g < N; g++) {
      int block = g / 64, t = g % 64;
      bad += hout[g] != hin[block * 64 + (63 - t)];
    }
    for (int i = N; i < N + GUARD; i++) stray += hout[i] != -1;
    printf("local shared: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
    failures += bad != 0 || stray != 0;
    cudaFree(din);
    cudaFree(dout);
  }

  /* k_global */
  {
    enum { N = 256 };
    int ho[N + GUARD];
    for (int i = 0; i < N + GUARD; i++) ho[i] = -1;
    int *dout;
    CK(cudaMalloc((void **)&dout, sizeof ho));
    CK(cudaMemcpy(dout, ho, sizeof ho, cudaMemcpyHostToDevice));
    void *args[] = { &dout };
    if (launch(kg, (dim3){1, 1, 1}, (dim3){256, 1, 1}, args)) return 1;
    CK(cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost));
    int bad = 0, stray = 0;
    for (int i = 0; i < N; i++) bad += ho[i] != 2 * i + 1;
    for (int i = N; i < N + GUARD; i++) stray += ho[i] != -1;
    printf("device global: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
    failures += bad != 0 || stray != 0;
    cudaFree(dout);
  }

  /* k_offset: out[i] = p[i].b - p[i].a with p[i] = {i, 3i + 1}, so out[i] = 2i + 1 */
  {
    enum { N = 1000 };
    typedef struct { int a, b; } Pair;
    Pair hp[N + GUARD];
    int ho[N + GUARD];
    for (int i = 0; i < N + GUARD; i++) { hp[i].a = i; hp[i].b = 3 * i + 1; ho[i] = -1; }
    Pair *dp; int *dout;
    CK(cudaMalloc((void **)&dp, sizeof hp));
    CK(cudaMalloc((void **)&dout, sizeof ho));
    CK(cudaMemcpy(dp, hp, sizeof hp, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dout, ho, sizeof ho, cudaMemcpyHostToDevice));
    int n = N;
    void *args[] = { &dout, &dp, &n };
    if (launch(ko, (dim3){8, 1, 1}, (dim3){128, 1, 1}, args)) return 1;
    CK(cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost));
    int bad = 0, stray = 0;
    for (int i = 0; i < N; i++) bad += ho[i] != 2 * i + 1;
    for (int i = N; i < N + GUARD; i++) stray += ho[i] != -1;
    printf("offset: %d elements, %d mismatches, %d guard writes\n", N, bad, stray);
    failures += bad != 0 || stray != 0;
    cudaFree(dp);
    cudaFree(dout);
  }

  CK(cudaLibraryUnload(lib));
  return failures != 0;
}
