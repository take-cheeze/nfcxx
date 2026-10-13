// The math functions llama.cpp's ggml-cuda calls and the prelude lowers (sinf, cosf, tanhf, expm1f, floorf, roundf,
// trunc, and the constants INFINITY and FLT_MAX), on the GPU against a double-precision reference.
// floorf, roundf, trunc: exact (bit for bit against the rounding of the double value).
// sinf, cosf, tanhf, expm1f: the device computes in double and rounds once; the measured error on 2^20 arguments in
// [-20000, 20000] and 2^18 arguments up to 1e6 is 0 ulp (correctly rounded on this grid). The bound checked here is
// 1 ulp against the double reference (CUDA's own sinf is within 2 ulp of it). Signed zeros, infinities and NaN are
// checked as the libm reference gives them.
// Arguments of sinf and cosf beyond 2^31 * pi / 2 (about 3.4e9) are not reduced (the nearest multiple overflows int).
#include <cuda_runtime.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { NA = 1 << 20, NB = 1 << 18, NE = 16 };
enum { N = NA + NB + NE };

__global__ void kmath(const float *x, float *s, float *c, float *t, float *e, float *fl, float *rd, float *tr, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  for (; i < n; i += gridDim.x * blockDim.x) {
    float v = x[i];
    s[i] = sinf(v); c[i] = cosf(v); t[i] = tanhf(v); e[i] = expm1f(v);
    fl[i] = floorf(v); rd[i] = roundf(v); tr[i] = trunc(v);
  }
}

__global__ void kconst(float *o) { o[0] = INFINITY; o[1] = FLT_MAX; o[2] = -INFINITY; }

/* ulp distance of got from the double reference; 0 for an exact match (and for NaN with NaN) */
static double ulps(float got, double ref) {
  if (isnan(ref)) return isnan(got) ? 0.0 : 1e30;
  if (isinf(ref)) return got == (float)ref ? 0.0 : 1e30;
  if (ref == 0.0) return (got == 0.0f && signbit(got) == signbit((float)ref)) ? 0.0 : 1e30;
  float r = (float)ref;
  if (got == r) return 0.0;
  float u = nextafterf(fabsf(r), INFINITY) - fabsf(r);
  return fabs((double)got - ref) / (double)u;
}

/* bitwise against the reference's float rounding, with NaN equal to NaN (payloads differ) */
static int same_float(float got, double ref) {
  if (isnan(ref)) return isnan(got);
  float r = (float)ref;
  return memcmp(&got, &r, 4) == 0;
}

static unsigned rng = 1u;
static float frand(float scale) {
  rng = rng * 1664525u + 1013904223u;
  return (2.0f * ((rng >> 8) / 16777216.0f) - 1.0f) * scale;
}

int main(void) {
  static float x[N], out[7][N];
  for (int i = 0; i < NA; i++) {
    float scale = (i & 3) == 0 ? 8.0f : (i & 3) == 1 ? 100.0f : (i & 3) == 2 ? 20000.0f : 1.0f;
    x[i] = frand(scale);
  }
  for (int i = 0; i < NB; i++) x[NA + i] = frand(1e6f);
  static const float edges[NE] = {0.0f, -0.0f, INFINITY, -INFINITY, NAN, 1e-40f, -1e-40f, 1e-30f,
                                  88.7f, -88.7f, 100.0f, -200.0f, 9.5f, -9.5f, 0.5f, -2.5f};
  memcpy(&x[NA + NB], edges, sizeof edges);

  float *dx, *d[7];
  cudaMalloc((void **)&dx, sizeof x);
  cudaMemcpy(dx, x, sizeof x, cudaMemcpyHostToDevice);
  for (int k = 0; k < 7; k++) cudaMalloc((void **)&d[k], sizeof out[k]);
  kmath<<<(N + 255) / 256, 256>>>(dx, d[0], d[1], d[2], d[3], d[4], d[5], d[6], N);
  cudaError_t err = cudaDeviceSynchronize();
  for (int k = 0; k < 7; k++) cudaMemcpy(out[k], d[k], sizeof out[k], cudaMemcpyDeviceToHost);
  float *dc; float hc[3];
  cudaMalloc((void **)&dc, sizeof hc);
  kconst<<<1, 1>>>(dc);
  cudaDeviceSynchronize();
  cudaMemcpy(hc, dc, sizeof hc, cudaMemcpyDeviceToHost);

  int bad = 0, checks = 0, badt = 0;
  double worst = 0.0;
  for (int i = 0; i < N; i++) {
    double v = x[i];
    double ref[7] = {sin(v), cos(v), tanh(v), expm1(v), floor(v), round(v), trunc(v)};
    for (int k = 0; k < 7; k++) {
      checks++;
      if (k >= 4) {  /* the rounding functions: exact */
        if (!same_float(out[k][i], ref[k])) { bad++; if (bad < 8) printf("  mismatch %d at x=%g: got %g want %g\n", k, v, out[k][i], ref[k]); }
      } else {
        double u = ulps(out[k][i], ref[k]);
        if (u > worst) worst = u;
        if (u > 1.0) { badt++; if (badt < 8) printf("  %s at x=%g: got %.9g want %.9g (%.2f ulp)\n", k == 0 ? "sinf" : k == 1 ? "cosf" : k == 2 ? "tanhf" : "expm1f", v, out[k][i], ref[k], u); }
      }
    }
  }
  bad += badt;
  /* INFINITY and FLT_MAX: the constants of <math.h> and <float.h> */
  checks += 3;
  bad += !(hc[0] == INFINITY) + !(hc[1] == FLT_MAX) + !(hc[2] == -INFINITY);
  printf("max transcendental error %.3f ulp over %d arguments\n", worst, N);
  printf("launch: %s\n", cudaGetErrorString(err));
  if (err != cudaSuccess || bad) {
    printf("math_fns: %d mismatches of %d checks\n", bad, checks);
    return 1;
  }
  printf("math_fns: no error, %d checks, 0 mismatches\n", checks);
  return 0;
}
