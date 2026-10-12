/* Runs the two kernels of helper.cpp (lowered to PTX with device helper functions) on 1000 elements, and checks
   every element and a guard region past each output. Usage: launch_helper FILE.cubin */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

enum { N = 1000, GUARD = 64 };

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s FILE.cubin\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  fclose(f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }

  cudaLibrary_t lib;
  cudaKernel_t kint, kscale;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  CK(cudaLibraryGetKernel(&kint, lib, "helper_kernel"));
  CK(cudaLibraryGetKernel(&kscale, lib, "helper_scale"));

  /* int kernel: out[i] = in[i]^2 + 1 */
  int hin[N + GUARD], hout[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) { hin[i] = i - 300; hout[i] = -7; }
  int *din, *dout;
  CK(cudaMalloc((void **)&din, sizeof hin));
  CK(cudaMalloc((void **)&dout, sizeof hout));
  CK(cudaMemcpy(din, hin, sizeof hin, cudaMemcpyHostToDevice));
  CK(cudaMemcpy(dout, hout, sizeof hout, cudaMemcpyHostToDevice));
  int n = N;
  void *args1[] = { &din, &dout, &n };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){8, 1, 1};
  cfg.blockDim = (dim3){128, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kint, args1));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));
  int bad_int = 0, stray_int = 0;
  for (int i = 0; i < N; i++) bad_int += hout[i] != hin[i] * hin[i] + 1;
  for (int i = N; i < N + GUARD; i++) stray_int += hout[i] != -7;

  /* float kernel: out[i] = in[i] * 0.5f + 1.0f */
  float fin[N + GUARD], fout[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) { fin[i] = 0.25f * (float)i; fout[i] = -7.0f; }
  float *fdin, *fdout;
  CK(cudaMalloc((void **)&fdin, sizeof fin));
  CK(cudaMalloc((void **)&fdout, sizeof fout));
  CK(cudaMemcpy(fdin, fin, sizeof fin, cudaMemcpyHostToDevice));
  CK(cudaMemcpy(fdout, fout, sizeof fout, cudaMemcpyHostToDevice));
  void *args2[] = { &fdin, &fdout, &n };
  CK(cudaLaunchKernelExC(&cfg, (const void *)kscale, args2));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(fout, fdout, sizeof fout, cudaMemcpyDeviceToHost));
  int bad_f = 0, stray_f = 0;
  for (int i = 0; i < N; i++) bad_f += fout[i] != fin[i] * 0.5f + 1.0f;
  for (int i = N; i < N + GUARD; i++) stray_f += fout[i] != -7.0f;

  printf("helper_kernel: %d mismatches, %d guard writes\n", bad_int, stray_int);
  printf("helper_scale: %d mismatches, %d guard writes\n", bad_f, stray_f);
  CK(cudaFree(din)); CK(cudaFree(dout)); CK(cudaFree(fdin)); CK(cudaFree(fdout));
  CK(cudaLibraryUnload(lib));
  return bad_int || stray_int || bad_f || stray_f;
}
