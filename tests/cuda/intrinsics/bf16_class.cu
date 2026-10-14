// nv_bfloat16 as a real class: a local of it in a kernel, its converting constructor and operator float, and the
// arithmetic (+, -, *, /, unary -), each result compared bit for bit with CUDA's host conversion of the float result
// (__float2bfloat16 of the float operation, as the header defines it). Also a local of a class with a destructor,
// which the device pass compiles with --no_exceptions.
#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <stdio.h>
#include <string.h>

#define N 20

__host__ __device__ inline unsigned short bits16(const __nv_bfloat16 &v) { return *reinterpret_cast<const unsigned short *>(&v); }

struct Guard {
  float v;
  __host__ __device__ Guard(float f) : v(f) {}
  __host__ __device__ ~Guard() {}
};

__global__ void k(const float *a, const float *b, unsigned short *add, unsigned short *sub, unsigned short *mul,
                  unsigned short *div, unsigned short *neg, float *guard) {
  int i = threadIdx.x;
  if (i < N) {
    __nv_bfloat16 x = __float2bfloat16(a[i]);
    __nv_bfloat16 y = __float2bfloat16(b[i]);
    add[i] = bits16(x + y);
    sub[i] = bits16(x - y);
    mul[i] = bits16(x * y);
    div[i] = bits16(x / y);
    neg[i] = bits16(-x);
    Guard g(a[i]);
    guard[i] = g.v * 2.0f;
  }
}

static unsigned short host_bits(float v) {
  __nv_bfloat16 h = __float2bfloat16(v);
  unsigned short u;
  memcpy(&u, &h, sizeof u);
  return u;
}

int main() {
  // Ties to even, a rounding boundary, overflow, underflow, NaN, infinities, signed zeros, ordinary values.
  const unsigned ab[N] = {0x3f808000u, 0x3f818000u, 0x3f800001u, 0x7f7fffffu, 0x00000001u, 0x7fc00001u, 0x7f800000u,
                          0xff800000u, 0x80000000u, 0x40200000u, 0xc0000000u, 0x3dcccccdu, 0x3f800000u, 0x42c80000u,
                          0x3fc00000u, 0xbf800000u, 0x00800000u, 0x4b000000u, 0x3f7fffffu, 0x40490fdbu};
  const unsigned bb[N] = {0x3f800000u, 0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u, 0x3f800000u, 0x3f800000u,
                          0x00000000u, 0x3f800000u, 0x3dcccccdu, 0x3f800001u, 0x7f800000u, 0x3f7fffffu, 0x42c80000u,
                          0x40000000u, 0x3f800000u, 0x40000000u, 0x3f800000u, 0x3f800001u, 0x41200000u};
  float a[N], b[N];
  memcpy(a, ab, sizeof a);
  memcpy(b, bb, sizeof b);

  float *da, *db, *dguard;
  unsigned short *dadd, *dsub, *dmul, *ddiv, *dneg;
  cudaMalloc((void **)&da, sizeof a);
  cudaMalloc((void **)&db, sizeof b);
  cudaMalloc((void **)&dguard, N * sizeof(float));
  cudaMalloc((void **)&dadd, N * sizeof(unsigned short));
  cudaMalloc((void **)&dsub, N * sizeof(unsigned short));
  cudaMalloc((void **)&dmul, N * sizeof(unsigned short));
  cudaMalloc((void **)&ddiv, N * sizeof(unsigned short));
  cudaMalloc((void **)&dneg, N * sizeof(unsigned short));
  cudaMemcpy(da, a, sizeof a, cudaMemcpyHostToDevice);
  cudaMemcpy(db, b, sizeof b, cudaMemcpyHostToDevice);
  k<<<1, N>>>(da, db, dadd, dsub, dmul, ddiv, dneg, dguard);

  unsigned short add[N], sub[N], mul[N], dv[N], neg[N];
  float guard[N];
  cudaMemcpy(add, dadd, sizeof add, cudaMemcpyDeviceToHost);
  cudaMemcpy(sub, dsub, sizeof sub, cudaMemcpyDeviceToHost);
  cudaMemcpy(mul, dmul, sizeof mul, cudaMemcpyDeviceToHost);
  cudaMemcpy(dv, ddiv, sizeof dv, cudaMemcpyDeviceToHost);
  cudaMemcpy(neg, dneg, sizeof neg, cudaMemcpyDeviceToHost);
  cudaMemcpy(guard, dguard, sizeof guard, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < N; i++) {
    // Operands are the bf16-rounded values, as the device computes them; each result is rounded to bf16 as CUDA's.
    float xr = __bfloat162float(__float2bfloat16(a[i])), yr = __bfloat162float(__float2bfloat16(b[i]));
    unsigned short want_add = host_bits(xr + yr), want_sub = host_bits(xr - yr), want_mul = host_bits(xr * yr);
    unsigned short want_div = host_bits(xr / yr), want_neg = host_bits(-xr);
    float x = a[i];
    if (add[i] != want_add) { printf("add %d: %04x != %04x\n", i, add[i], want_add); bad++; }
    if (sub[i] != want_sub) { printf("sub %d: %04x != %04x\n", i, sub[i], want_sub); bad++; }
    if (mul[i] != want_mul) { printf("mul %d: %04x != %04x\n", i, mul[i], want_mul); bad++; }
    if (dv[i] != want_div) { printf("div %d: %04x != %04x\n", i, dv[i], want_div); bad++; }
    if (neg[i] != want_neg) { printf("neg %d: %04x != %04x\n", i, neg[i], want_neg); bad++; }
    float want_guard = x * 2.0f;
    if (memcmp(&guard[i], &want_guard, sizeof(float)) != 0 && !(guard[i] != guard[i] && want_guard != want_guard)) {
      printf("guard %d: %g != %g\n", i, guard[i], want_guard);
      bad++;
    }
  }
  printf("bf16 class: %s, %d mismatches\n", bad ? "FAIL" : "no error", bad);

  cudaFree(da); cudaFree(db); cudaFree(dguard); cudaFree(dadd); cudaFree(dsub); cudaFree(dmul); cudaFree(ddiv); cudaFree(dneg);
  return bad ? 1 : 0;
}
