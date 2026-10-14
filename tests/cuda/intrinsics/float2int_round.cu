// __float2int_rn on the device (cvt.rni.s32.f32) against the host's rint: round to nearest, even, then saturate to the int
// range, and NaN gives 0. Covers the .5 ties of both signs, the saturation bounds, infinities, NaN and random bit patterns.
#include <cuda_runtime.h>
#include <math.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

__global__ void k(const float *x, int *r, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) r[i] = __float2int_rn(x[i]);
}

// rint in double is exact for a float, and rounds to nearest even under the default mode.
static int reference(float f) {
  if (f != f) return 0;
  double d = rint((double)f);
  if (d >= 2147483648.0) return INT_MAX;
  if (d < -2147483648.0) return INT_MIN;
  return (int)d;
}

static unsigned int seed = 777u;
static unsigned int next_u32(void) { seed = seed * 1664525u + 1013904223u; return seed; }

int main() {
  const float special[] = {0.0f, -0.0f, 0.5f, -0.5f, 1.5f, -1.5f, 2.5f, -2.5f, 3.5f, -3.5f, 0.49999997f, 0.50000006f,
                           2.4999998f, 3.7f, -3.7f, 4194303.5f, 4194304.5f, 2147483520.0f, 2147483648.0f, -2147483648.0f,
                           -2147483904.0f, 1e30f, -1e30f, INFINITY, -INFINITY, NAN, -NAN};
  const int ns = sizeof special / sizeof special[0];
  const int nr = 1000000, nt = 100000;
  const int n = ns + nr + nt;
  float *x = new float[n];
  int *got = new int[n];
  int i = 0;
  for (int s = 0; s < ns; s++) x[i++] = special[s];
  // Random bit patterns: every class of float, including NaN and infinity.
  for (int r = 0; r < nr; r++) { unsigned int u = next_u32(); memcpy(&x[i++], &u, 4); }
  // Ties: halves of random integers, spanning the whole int range and both signs.
  int ties = 0;
  for (int t = 0; t < nt; t++) {
    double v = ((double)(next_u32() % 4000000001u) - 2000000000.0) / 2.0;
    x[i] = (float)v;
    if (fabs(fabs(x[i] - floor(x[i])) - 0.5) < 1e-9) ties++;
    i++;
  }

  float *dx;
  int *dr;
  cudaMalloc((void **)&dx, n * sizeof(float));
  cudaMalloc((void **)&dr, n * sizeof(int));
  cudaMemcpy(dx, x, n * sizeof(float), cudaMemcpyHostToDevice);
  k<<<(n + 255) / 256, 256>>>(dx, dr, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(got, dr, n * sizeof(int), cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int j = 0; j < n; j++) {
    int want = reference(x[j]);
    if (got[j] != want) {
      if (bad < 5) printf("  x=%.9g got %d want %d\n", x[j], got[j], want);
      bad++;
    }
  }
  printf("float2int_rn: %s, %d mismatches, %d cases, %d ties\n", cudaGetErrorString(err), bad, n, ties);
  cudaFree(dx); cudaFree(dr);
  delete[] x; delete[] got;
  return bad != 0;
}
