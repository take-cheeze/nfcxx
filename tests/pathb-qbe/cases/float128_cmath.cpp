// <cmath> on __float128 (docs/notes/pathb-float128.md): std::abs reaches the built-in fabsf128, which is called through its
// wrapper (be/nfcxx_ldrt.c), and the classification built-ins of a _Float128 are helpers of the same library. The values
// are printed as their bit patterns, compared with the gcc backend.
// STDOUT: same
// EXPECT: 0
#include <cmath>
#include <cstdio>
#include <cstring>

typedef __float128 f128;

static void prq(const char *tag, f128 x) {
  unsigned long long w[2];
  std::memcpy(w, &x, sizeof w);
  std::printf("%s %016llx%016llx\n", tag, w[1], w[0]);
}

static volatile f128 vneg = -2.5;

int main() {
  f128 a = std::abs(vneg);
  prq("abs", a);
  prq("abs-of-zero", std::abs((f128)-0.0));
  std::printf("isnan %d isinf %d finite %d\n", (int)__builtin_isnan(a), (int)__builtin_isinf(a), (int)__builtin_isfinite(a));
  return a == 2.5 ? 0 : 1;
}
