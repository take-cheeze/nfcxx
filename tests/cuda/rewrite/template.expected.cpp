#line 1 "rewrite/template.cu"
// A template kernel, launched with explicit arguments from a host function; a helper that the kernel calls; and a
// constant the kernel reads. Host-only declarations stay out of the device unit.
#include <cstdio>

typedef unsigned int uint;
#define SCALE 3

template <int N, class T> static void scaled(T *out, const T *in, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = in[i] * N + helper<T>(i);
}

template <class T> static T helper(int i)
{
  return (T)(i % SCALE);
}

static const int kLimit = 64;
struct HostOnly { int x; void run(); };

void HostOnly::run() { printf("%d\n", x); }static void __nfcxx_k_scaled_2_float(float *out, const float *in, int n);


int main() {
  float *a = 0, *b = 0;
  __nfcxx_cuda_launch(__nfcxx_k_scaled_2_float, 4, 16, 0, 0, a, b, kLimit);
  return 0;
}

static void __nfcxx_k_scaled_2_float(float *out, const float *in, int n) {}
