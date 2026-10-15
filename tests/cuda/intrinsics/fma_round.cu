// __hfma on the device (fma.rn.f16) against the correctly rounded fused multiply-add on the host. The reference computes
// a*b + c in double (the product of two halves is exact in double, and the sum rounds once) and rounds to half with
// CUDA's __double2half. Rounding to half from double cannot differ from rounding once (53 >= 2*11 + 2), so this is the
// exact result. The float route (a float product and sum, then __float2half) rounds twice, and differs on some triples:
// the test collects those, plus random finite triples, and checks the device on every one.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>
#include <string.h>

// The host copy of the kernel needs __hfma, which the CUDA host headers do not declare; the device pass uses the
// prelude's. This host function is not kept in the device unit (it is never run).
static __half __hfma(__half a, __half b, __half c) {
  return __float2half(__half2float(a) * __half2float(b) + __half2float(c));
}

__global__ void k(const unsigned short *a, const unsigned short *b, const unsigned short *c, unsigned short *r, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __half x = (__half)a[i];
  __half y = (__half)b[i];
  __half z = (__half)c[i];
  __half f = __hfma(x, y, z);
  r[i] = *(unsigned short *)&f;
}

static unsigned short to_bits(__half h) { unsigned short u; memcpy(&u, &h, 2); return u; }
static __half from_bits(unsigned short u) { __half h; memcpy(&h, &u, 2); return h; }

// The correctly rounded fma.
static unsigned short exact_fma(unsigned short a, unsigned short b, unsigned short c) {
  double d = (double)__half2float(from_bits(a)) * (double)__half2float(from_bits(b)) + (double)__half2float(from_bits(c));
  return to_bits(__double2half(d));
}

// The float route, which rounds twice.
static unsigned short float_route(unsigned short a, unsigned short b, unsigned short c) {
  float fa = __half2float(from_bits(a)), fb = __half2float(from_bits(b)), fc = __half2float(from_bits(c));
  return to_bits(__float2half(fa * fb + fc));
}

static unsigned int seed = 12345u;
static unsigned int next_u32(void) { seed = seed * 1664525u + 1013904223u; return seed; }
// A random finite half (exponent field below 31: no inf or NaN).
static unsigned short finite_half(void) {
  unsigned short u;
  do { u = (unsigned short)(next_u32() >> 16); } while (((u >> 10) & 31) == 31);
  return u;
}

int main() {
  const int want_dr = 4096, want_plain = 4096, want_edge = 11 * 11;
  const int cap = want_dr + want_plain + want_edge;
  static unsigned short A[cap], B[cap], C[cap];
  int n = 0, dr = 0;
  // Triples where the float route differs from the exact result, then random triples, which mostly agree.
  for (long t = 0; dr < want_dr && t < 200000000L; t++) {
    unsigned short a = finite_half(), b = finite_half(), c = finite_half();
    if (exact_fma(a, b, c) != float_route(a, b, c)) {
      A[n] = a; B[n] = b; C[n] = c; n++; dr++;
    }
  }
  for (int p = 0; p < want_plain; p++) {
    A[n] = finite_half(); B[n] = finite_half(); C[n] = finite_half(); n++;
  }
  // The signed zeros, the largest and the smallest subnormal, and the overflow boundary.
  const unsigned short edge[] = {0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x7bff, 0xfbff, 0x3c00, 0xbc00, 0x3555, 0x4000};
  const int ne = sizeof edge / sizeof edge[0];
  for (int i = 0; i < ne; i++)
    for (int j = 0; j < ne; j++) {
      A[n] = edge[i]; B[n] = edge[j]; C[n] = edge[(i + j) % ne]; n++;
    }

  unsigned short *da, *db, *dc, *dr_out;
  cudaMalloc((void **)&da, n * 2); cudaMalloc((void **)&db, n * 2); cudaMalloc((void **)&dc, n * 2);
  cudaMalloc((void **)&dr_out, n * 2);
  cudaMemcpy(da, A, n * 2, cudaMemcpyHostToDevice);
  cudaMemcpy(db, B, n * 2, cudaMemcpyHostToDevice);
  cudaMemcpy(dc, C, n * 2, cudaMemcpyHostToDevice);
  k<<<(n + 255) / 256, 256>>>(da, db, dc, dr_out, n);
  cudaError_t err = cudaDeviceSynchronize();
  unsigned short *got = new unsigned short[n];
  cudaMemcpy(got, dr_out, n * 2, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < n; i++) {
    unsigned short want = exact_fma(A[i], B[i], C[i]);
    if (got[i] != want && bad++ < 4) printf("  %04x*%04x+%04x got %04x want %04x\n", A[i], B[i], C[i], got[i], want);
  }
  if (dr < want_dr) bad++;  // the float route must differ somewhere, or the test is vacuous
  printf("half fma: %s, %d mismatches, %d double-rounding cases of %d\n", cudaGetErrorString(err), bad, dr, n);
  delete[] got;
  cudaFree(da); cudaFree(db); cudaFree(dc); cudaFree(dr_out);
  return bad != 0;
}
