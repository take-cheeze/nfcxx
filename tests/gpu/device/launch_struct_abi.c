/* Runs struct_kernel (struct_abi.cpp, or nvcc's struct_abi_ref.cu) on 1000 elements. The structs are passed from the host
   in the argument array, one pointer per argument (the nvcc way: the runtime copies each argument by the kernel's
   parameter layout). Checks every element against the host's values and a guard region past the output, and prints a
   checksum of the output, so two cubins can be compared. Usage: launch_struct_abi FILE.cubin */
#include <cuda_runtime.h>
#include <stdio.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); return 1; } } while (0)

enum { N = 1000, GUARD = 64 };

typedef struct { int a; int b; } P8;                                  /* 8 bytes, alignment 4 */
typedef struct { int a; short b; char c; float d; } M12;              /* 12 bytes, alignment 4 */
typedef struct { float x, y, z, w; } __attribute__((aligned(16))) V16; /* 16 bytes, alignment 16 */
typedef union { int i; float f; } U;                                  /* 4 bytes */
typedef struct { P8 p; float f; } Outer;                              /* 12 bytes, nested */

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: %s FILE.cubin\n", argv[0]); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  static char img[1 << 20];
  size_t len = fread(img, 1, sizeof img, f);
  fclose(f);
  if (len == 0 || len == sizeof img) { fprintf(stderr, "bad cubin size %zu\n", len); return 2; }

  cudaLibrary_t lib;
  cudaKernel_t kern;
  CK(cudaLibraryLoadData(&lib, img, NULL, NULL, 0, NULL, NULL, 0));
  CK(cudaLibraryGetKernel(&kern, lib, "struct_kernel"));

  P8 p = { 3, 5 };
  U u; u.i = 7;
  V16 v = { 1.0f, 2.0f, 3.0f, 4.0f };
  M12 m = { 10, -2, 3, 4.0f };
  int n = N;

  static int hout[N + GUARD];
  for (int i = 0; i < N + GUARD; i++) hout[i] = -7;
  int *dout;
  CK(cudaMalloc((void **)&dout, sizeof hout));
  CK(cudaMemcpy(dout, hout, sizeof hout, cudaMemcpyHostToDevice));
  void *args[] = { &dout, &n, &p, &u, &v, &m };
  cudaLaunchConfig_t cfg = {0};
  cfg.gridDim = (dim3){8, 1, 1};
  cfg.blockDim = (dim3){128, 1, 1};
  CK(cudaLaunchKernelExC(&cfg, (const void *)kern, args));
  CK(cudaDeviceSynchronize());
  CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));

  /* The host's values: sum_p8(mk_p8(p.a + i, p.b)) + u_read(u) + sum_v16(scale_v16(v, n)) + sum_m12(bump_m12(m with a += i))
     + nest_outer({ mk_p8(p.a + i, p.b), n }) + empty_arg(E{}, i) (the empty argument is nothing: the k is i) */
  int bad = 0, stray = 0;
  long long sum = 0;
  float s = (float)n;
  float sv = v.x * s + v.y * s + v.z * s + v.w * s;
  for (int i = 0; i < N; i++) {
    int q = (p.a + i) + p.b;
    M12 bm = m;
    bm.a += i;
    bm.a += 1;
    bm.d *= 2.0f;
    int nest = q + (int)s;
    int want = q + u.i + (int)sv + (bm.a + bm.b + bm.c + (int)bm.d) + nest + i;
    bad += hout[i] != want;
    sum += hout[i];
  }
  for (int i = N; i < N + GUARD; i++) stray += hout[i] != -7;
  printf("struct_kernel: %d mismatches, %d guard writes, checksum %lld\n", bad, stray, sum);
  CK(cudaFree(dout));
  CK(cudaLibraryUnload(lib));
  return bad || stray;
}
