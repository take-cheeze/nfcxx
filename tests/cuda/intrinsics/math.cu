// The float math functions and __dp4a, __ldg, __saturatef of ggml-cuda, on the GPU against the host.
// Exact functions must match bit for bit: fmaxf, fminf (CUDA's NaN rule), fabsf, sqrtf (correctly rounded),
// __saturatef, __dp4a, __ldg. Approximate ones are checked within a tolerance (their PTX is approximate):
// rsqrtf and __fdividef (rsqrt.approx, div.approx), expf and __expf (ex2.approx of x*log2e), logf and __logf
// (lg2.approx times ln2). Tolerance: |got - ref| <= 1e-5 * (1 + |ref|).
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { N = 4096 };

__global__ void kmath(const float *a, const float *b, const int *ia, const int *ib, const unsigned *up,
                      float *out, int *iout, unsigned *uout) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= N) return;
  float x = a[i], y = b[i];
  out[0 * N + i] = fmaxf(x, y);
  out[1 * N + i] = fminf(x, y);
  out[2 * N + i] = fabsf(x);
  out[3 * N + i] = sqrtf(fabsf(x));
  out[4 * N + i] = rsqrtf(fabsf(x) + 1e-3f);
  out[5 * N + i] = __fdividef(x, y == 0.0f ? 1.0f : y);
  out[6 * N + i] = expf(x * 0.25f);
  out[7 * N + i] = __expf(x * 0.25f);
  out[8 * N + i] = logf(fabsf(x) + 1e-3f);
  out[9 * N + i] = __logf(fabsf(x) + 1e-3f);
  out[10 * N + i] = __saturatef(x);
  out[11 * N + i] = __ldg(&a[i]);
  iout[i] = __dp4a(ia[i], ib[i], i);
  uout[i] = (unsigned)__ldg(&ia[i]) + up[i] * 0u;
}

static unsigned rng = 12345u;
static float frand(void) {  // deterministic values in [-8, 8), with the special values sprinkled in
  rng = rng * 1103515245u + 12345u;
  float v = ((rng >> 8) % 1600000u) / 100000.0f - 8.0f;
  return v;
}

static int near_ok(double got, double ref) {  /* a NaN reference needs a NaN result */
  if (isnan(ref)) return isnan(got);
  return fabs(got - ref) <= 1e-5 * (1.0 + fabs(ref));
}

static int same_float(float got, float ref) {  /* bitwise, with NaN equal to NaN (NaN payloads differ) */
  if (isnan(ref)) return isnan(got);
  return memcmp(&got, &ref, 4) == 0;
}

int main(void) {
  static float a[N], b[N], outh[12 * N];
  static int ia[N], ib[N], iouth[N];
  static unsigned up[N], uouth[N];
  for (int i = 0; i < N; i++) {
    a[i] = frand();
    b[i] = (i % 17 == 0) ? 0.0f : frand();
    ia[i] = (int)(rng = rng * 1103515245u + 12345u);
    ib[i] = (int)(rng = rng * 1103515245u + 12345u);
    up[i] = (unsigned)i;
  }
  a[5] = NAN;      // fmaxf(NaN, y) = y, fminf(NaN, y) = y (CUDA)
  b[6] = NAN;
  a[7] = 0.0f;     // saturatef(0) = 0

  float *da, *db, *dout;
  int *dia, *dib, *diout;
  unsigned *dup, *duout;
  cudaMalloc((void **)&da, sizeof a); cudaMalloc((void **)&db, sizeof b);
  cudaMalloc((void **)&dout, sizeof outh);
  cudaMalloc((void **)&dia, sizeof ia); cudaMalloc((void **)&dib, sizeof ib);
  cudaMalloc((void **)&diout, sizeof iouth);
  cudaMalloc((void **)&dup, sizeof up); cudaMalloc((void **)&duout, sizeof uouth);
  cudaMemcpy(da, a, sizeof a, cudaMemcpyHostToDevice);
  cudaMemcpy(db, b, sizeof b, cudaMemcpyHostToDevice);
  cudaMemcpy(dia, ia, sizeof ia, cudaMemcpyHostToDevice);
  cudaMemcpy(dib, ib, sizeof ib, cudaMemcpyHostToDevice);
  cudaMemcpy(dup, up, sizeof up, cudaMemcpyHostToDevice);
  kmath<<<(N + 255) / 256, 256>>>(da, db, dia, dib, dup, dout, diout, duout);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(outh, dout, sizeof outh, cudaMemcpyDeviceToHost);
  cudaMemcpy(iouth, diout, sizeof iouth, cudaMemcpyDeviceToHost);
  cudaMemcpy(uouth, duout, sizeof uouth, cudaMemcpyDeviceToHost);

  int bad = 0, checks = 0;
  for (int i = 0; i < N; i++) {
    float x = a[i], y = b[i];
    float *o = outh;
    float fmx = (isnan(x) && !isnan(y)) ? y : (isnan(y) && !isnan(x)) ? x : fmaxf(x, y);
    float fmn = (isnan(x) && !isnan(y)) ? y : (isnan(y) && !isnan(x)) ? x : fminf(x, y);
    checks++; bad += !same_float(o[0 * N + i], fmx);
    checks++; bad += !same_float(o[1 * N + i], fmn);
    float fab = fabsf(x);
    checks++; bad += !same_float(o[2 * N + i], fab);
    float sq = sqrtf(fabsf(x));
    checks++; bad += !same_float(o[3 * N + i], sq);
    float sat = x <= 0.0f ? 0.0f : x >= 1.0f ? 1.0f : x;
    if (isnan(x)) sat = 0.0f;
    checks++; bad += !same_float(o[10 * N + i], sat);
    float ld = x;
    checks++; bad += !same_float(o[11 * N + i], ld);
    /* __dp4a: the signed dot product of the four byte lanes of ia[i] and ib[i], plus i */
    int acc = i;
    for (int k = 0; k < 4; k++) {
      int8_t p = (int8_t)((unsigned)ia[i] >> (8 * k)), q = (int8_t)((unsigned)ib[i] >> (8 * k));
      acc += (int)p * (int)q;
    }
    checks++; bad += iouth[i] != acc;
    checks++; bad += uouth[i] != (unsigned)ia[i];
    /* approximate ones */
    double r = 1.0 / sqrt((double)fabsf(x) + 1e-3);
    checks++; bad += !near_ok(o[4 * N + i], r);
    double q = y == 0.0f ? (double)x : (double)x / (double)y;
    checks++; bad += !near_ok(o[5 * N + i], q);
    double e = exp((double)x * 0.25);
    checks++; bad += !near_ok(o[6 * N + i], e);
    checks++; bad += !near_ok(o[7 * N + i], e);
    double l = log((double)fabsf(x) + 1e-3);
    checks++; bad += !near_ok(o[8 * N + i], l);
    checks++; bad += !near_ok(o[9 * N + i], l);
  }
  printf("math: %s, %d checks, %d mismatches\n", cudaGetErrorString(err), checks, bad);
  return bad != 0;
}
