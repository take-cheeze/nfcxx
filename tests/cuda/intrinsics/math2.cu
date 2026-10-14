// The remaining math names of ggml-cuda's device code and the limits it uses, on the GPU against the host libm.
// fmaf and ceilf: exact (one PTX instruction each: fma.rn.f32, cvt.rpi). Checked bit for bit against libm's fmaf and
//   ceilf over random and edge arguments.
// log2f: an exact exponent at every power of two (checked for all exponents), else lg2.approx.f32, within 2 ulp of
//   libm's log2f (or within 2^-22 absolute, which covers results near zero at x near 1).
// erff: the device computes the Maclaurin series of erf in double and rounds once. Checked within 2 ulp of libm's erff
//   (glibc's erff is within 1 ulp of the correctly rounded value).
// INT_MAX, INT_MIN, UINT_MAX: the limits, exact.
#include <cuda_runtime.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { NA = 1 << 19, NE = 16, NP = 256 };
enum { N = NA + NE + NP };

__global__ void kfma(const float *a, const float *b, const float *c, float *o, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  for (; i < n; i += gridDim.x * blockDim.x) o[i] = fmaf(a[i], b[i], c[i]);
}

__global__ void kunary(const float *x, float *ceil_o, float *log2_o, float *erf_o, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  for (; i < n; i += gridDim.x * blockDim.x) {
    ceil_o[i] = ceilf(x[i]);
    log2_o[i] = log2f(x[i]);
    erf_o[i] = erff(x[i]);
  }
}

__global__ void klimits(int *o) { o[0] = INT_MAX; o[1] = INT_MIN; o[2] = (int)UINT_MAX; }

/* ulp distance of got from the libm reference; 0 for an exact match (and NaN with NaN) */
static double ulps(float got, float ref) {
  if (isnan(ref)) return isnan(got) ? 0.0 : 1e30;
  if (isinf(ref)) return got == ref ? 0.0 : 1e30;
  if (got == ref) return 0.0;
  float u = nextafterf(fabsf(ref), INFINITY) - fabsf(ref);
  return fabs((double)got - (double)ref) / (double)u;
}

static unsigned rng = 1u;
static float frand(float scale) {
  rng = rng * 1664525u + 1013904223u;
  return (2.0f * ((rng >> 8) / 16777216.0f) - 1.0f) * scale;
}

static int same_bits(float got, float ref) {
  if (isnan(ref)) return isnan(got);
  return memcmp(&got, &ref, 4) == 0;
}

static int fail = 0;

int main(void) {
  static float a[N], b[N], c[N], x[N];
  static float d_fma[N], d_ceil[N], d_log2[N], d_erf[N];
  for (int i = 0; i < NA; i++) {
    float scale = (i & 3) == 0 ? 1.0f : (i & 3) == 1 ? 1000.0f : (i & 3) == 2 ? 1e-3f : 1e6f;
    a[i] = frand(scale); b[i] = frand(scale); c[i] = frand(scale * 3.0f);
    x[i] = frand(scale);
  }
  /* edge values: zeros, infinities, NaN, subnormals, large and near-one arguments */
  static const float edges[NE] = {0.0f, -0.0f, INFINITY, -INFINITY, NAN, 1e-40f, -1e-40f, 1e-30f,
                                  1.0f, 0.5f, -0.5f, 3.0f, 8.0f, -8.0f, 1e30f, -1e30f};
  for (int i = 0; i < NE; i++) {
    a[NA + i] = edges[i]; b[NA + i] = edges[(i + 5) % NE]; c[NA + i] = edges[(i + 9) % NE];
    x[NA + i] = edges[i];
  }
  for (int i = 0; i < NP; i++) {   /* powers of two, every exponent in the float range */
    int e = (i % 254) - 126;
    x[NA + NE + i] = ldexpf(1.0f, e);
  }

  float *da, *db, *dc, *dx, *dfma, *dceil, *dlog2, *derf;
  cudaMalloc(&da, N * 4); cudaMalloc(&db, N * 4); cudaMalloc(&dc, N * 4); cudaMalloc(&dx, N * 4);
  cudaMalloc(&dfma, N * 4); cudaMalloc(&dceil, N * 4); cudaMalloc(&dlog2, N * 4); cudaMalloc(&derf, N * 4);
  cudaMemcpy(da, a, N * 4, cudaMemcpyHostToDevice);
  cudaMemcpy(db, b, N * 4, cudaMemcpyHostToDevice);
  cudaMemcpy(dc, c, N * 4, cudaMemcpyHostToDevice);
  cudaMemcpy(dx, x, N * 4, cudaMemcpyHostToDevice);
  kfma<<<(N + 255) / 256, 256>>>(da, db, dc, dfma, N);
  kunary<<<(N + 255) / 256, 256>>>(dx, dceil, dlog2, derf, N);
  cudaDeviceSynchronize();
  cudaMemcpy(d_fma, dfma, N * 4, cudaMemcpyDeviceToHost);
  cudaMemcpy(d_ceil, dceil, N * 4, cudaMemcpyDeviceToHost);
  cudaMemcpy(d_log2, dlog2, N * 4, cudaMemcpyDeviceToHost);
  cudaMemcpy(d_erf, derf, N * 4, cudaMemcpyDeviceToHost);

  int bad_fma = 0, bad_ceil = 0, bad_pow2 = 0, bad_erf = 0, bad_log2 = 0;
  double max_log2_abs = 0.0, max_erf_ulp = 0.0;
  float worst_x = 0.0f, worst_got = 0.0f, worst_ref = 0.0f;
  for (int i = 0; i < N; i++) {
    if (!same_bits(d_fma[i], fmaf(a[i], b[i], c[i]))) bad_fma++;
    if (!same_bits(d_ceil[i], ceilf(x[i]))) bad_ceil++;
    float rl = log2f(x[i]);
    if (i >= NA + NE) {   /* the powers of two: exact */
      if (!same_bits(d_log2[i], rl)) bad_pow2++;
    } else if (!isnan(rl) && !isinf(rl)) {
      double ue = ulps(d_log2[i], rl), ae = fabs((double)d_log2[i] - (double)rl);
      if (ae > max_log2_abs) max_log2_abs = ae;
      if (ue > 2.0 && ae > 2.384185791015625e-7) { bad_log2++; worst_x = x[i]; worst_got = d_log2[i]; worst_ref = rl; }
    }
    double ue = ulps(d_erf[i], erff(x[i]));
    if (ue > max_erf_ulp) max_erf_ulp = ue;
    if (ue > 2.0) bad_erf++;
  }
  /* lg2.approx: within 2 ulp of libm's log2f, or within 2^-22 absolute (near 1 the result is tiny and an ulp bound is too tight) */
  int log2_ok = bad_log2 == 0;
  if (bad_fma || !log2_ok || bad_pow2 || bad_ceil || bad_erf) fail = 1;
  printf("fmaf: %d mismatches of %d (bitwise against libm)\n", bad_fma, N);
  printf("ceilf: %d mismatches of %d (bitwise against libm)\n", bad_ceil, N);
  printf("log2f: %d powers of two not exact; %d points outside 2 ulp and 2^-22 (max absolute error %.3g)\n", bad_pow2, bad_log2, max_log2_abs);
  printf("erff: %d over 2 ulp; max %.2f ulp against libm\n", bad_erf, max_erf_ulp);

  int *dl; cudaMalloc(&dl, 3 * sizeof(int));
  klimits<<<1, 1>>>(dl);
  int lim[3];
  cudaMemcpy(lim, dl, sizeof lim, cudaMemcpyDeviceToHost);
  if (lim[0] != INT_MAX || lim[1] != INT_MIN || (unsigned)lim[2] != UINT_MAX) fail = 1;
  printf("limits: INT_MAX %d INT_MIN %d UINT_MAX %u\n", lim[0], lim[1], (unsigned)lim[2]);

  cudaFree(da); cudaFree(db); cudaFree(dc); cudaFree(dx);
  cudaFree(dfma); cudaFree(dceil); cudaFree(dlog2); cudaFree(derf); cudaFree(dl);
  printf("%s\n", fail ? "math2: FAILED" : "math2: no error, 0 mismatches");
  return fail;
}
