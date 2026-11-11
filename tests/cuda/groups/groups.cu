// Kernels split into several device modules (pathb-ptx-emit --groups-dir; the driver embeds one cubin per module and the
// runtime loads each kernel from its own module). run.sh forces the split: a 300-byte constant budget puts each 256-byte
// table's kernel in its own module, and a small PTX-line budget splits the kernels by their functions. The helper mix() is
// called from every kernel, so each module that needs it has its own copy (a .func, not .visible). The host checks every
// element. The GROUPS_MUTANT build changes one device table entry (not the host copy): the check must fail.
#include <cuda_runtime.h>
#include <stdio.h>

// the same values on the host and the device
#define TAB_A {11, 48, 85, 21, 58, 95, 31, 68, 4, 41, 78, 14, 51, 88, 24, 61, 98, 34, 71, 7, 44, 81, 17, 54, 91, 27, 64, 0, 37, 74, 10, 47, 84, 20, 57, 94, 30, 67, 3, 40, 77, 13, 50, 87, 23, 60, 97, 33, 70, 6, 43, 80, 16, 53, 90, 26, 63, 100, 36, 73, 9, 46, 83, 19}
#define TAB_B {7, 60, 16, 69, 25, 78, 34, 87, 43, 96, 52, 8, 61, 17, 70, 26, 79, 35, 88, 44, 0, 53, 9, 62, 18, 71, 27, 80, 36, 89, 45, 1, 54, 10, 63, 19, 72, 28, 81, 37, 90, 46, 2, 55, 11, 64, 20, 73, 29, 82, 38, 91, 47, 3, 56, 12, 65, 21, 74, 30, 83, 39, 92, 48}
#define TAB_C {0, 1, 4, 9, 16, 25, 5, 18, 2, 19, 7, 28, 20, 14, 10, 8, 8, 10, 14, 20, 28, 7, 19, 2, 18, 5, 25, 16, 9, 4, 1, 0, 1, 4, 9, 16, 25, 5, 18, 2, 19, 7, 28, 20, 14, 10, 8, 8, 10, 14, 20, 28, 7, 19, 2, 18, 5, 25, 16, 9, 4, 1, 0, 1}

static const int tab_a[64] = {11, 48, 85, 21, 58, 95, 31, 68, 4, 41, 78, 14, 51, 88, 24, 61, 98, 34, 71, 7, 44, 81, 17, 54, 91, 27, 64, 0, 37, 74, 10, 47, 84, 20, 57, 94, 30, 67, 3, 40, 77, 13, 50, 87, 23, 60, 97, 33, 70, 6, 43, 80, 16, 53, 90, 26, 63, 100, 36, 73, 9, 46, 83, 19};
static const int tab_b[64] = {7, 60, 16, 69, 25, 78, 34, 87, 43, 96, 52, 8, 61, 17, 70, 26, 79, 35, 88, 44, 0, 53, 9, 62, 18, 71, 27, 80, 36, 89, 45, 1, 54, 10, 63, 19, 72, 28, 81, 37, 90, 46, 2, 55, 11, 64, 20, 73, 29, 82, 38, 91, 47, 3, 56, 12, 65, 21, 74, 30, 83, 39, 92, 48};
static const int tab_c[64] = {0, 1, 4, 9, 16, 25, 5, 18, 2, 19, 7, 28, 20, 14, 10, 8, 8, 10, 14, 20, 28, 7, 19, 2, 18, 5, 25, 16, 9, 4, 1, 0, 1, 4, 9, 16, 25, 5, 18, 2, 19, 7, 28, 20, 14, 10, 8, 8, 10, 14, 20, 28, 7, 19, 2, 18, 5, 25, 16, 9, 4, 1, 0, 1};

__device__ int mix(int x) { return x * 7 + 3; }

__global__ void k_a(int *o) {
  int i = threadIdx.x;
  o[i] = tab_a[i & 63] + mix(i);
}

__global__ void k_b(int *o) {
  int i = threadIdx.x;
#ifdef GROUPS_MUTANT
  o[i] = (i == 5 ? 1 : tab_b[i & 63]) * 2 - mix(i);
#else
  o[i] = tab_b[i & 63] * 2 - mix(i);
#endif
}

__global__ void k_c(int *o) {
  int i = threadIdx.x;
  o[i] = tab_c[i & 63] ^ mix(i);
}

__global__ void k_d(int *o) {
  int i = threadIdx.x;
  o[i] = mix(i) + 1;
}

static int host_mix(int x) { return x * 7 + 3; }

// the device results of one kernel (256 threads) checked against the host expression
static int check(const char *name, const int *h, int (*expect)(int)) {
  int bad = 0;
  for (int i = 0; i < 256; i++) bad += h[i] != expect(i);
  printf("groups %s: %d mismatches\n", name, bad);
  return bad;
}

static const int ha[64] = TAB_A;
static const int hb[64] = TAB_B;
static const int hc[64] = TAB_C;

static int exp_a(int i) { return ha[i & 63] + host_mix(i); }
static int exp_b(int i) { return hb[i & 63] * 2 - host_mix(i); }
static int exp_c(int i) { return hc[i & 63] ^ host_mix(i); }
static int exp_d(int i) { return host_mix(i) + 1; }

int main() {
  int *d;
  int h[256];
  cudaMalloc((void **)&d, sizeof h);
  int bad = 0;
  k_a<<<1, 256>>>(d);
  if (cudaDeviceSynchronize() != cudaSuccess) return 1;
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  bad += check("a", h, exp_a);
  k_b<<<1, 256>>>(d);
  if (cudaDeviceSynchronize() != cudaSuccess) return 1;
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  bad += check("b", h, exp_b);
  k_c<<<1, 256>>>(d);
  if (cudaDeviceSynchronize() != cudaSuccess) return 1;
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  bad += check("c", h, exp_c);
  k_d<<<1, 256>>>(d);
  if (cudaDeviceSynchronize() != cudaSuccess) return 1;
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  bad += check("d", h, exp_d);
  cudaFree(d);
  printf("groups: %s, %d mismatches\n", bad ? "FAILED" : "no error", bad);
  return bad != 0;
}
