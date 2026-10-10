// __int128 and unsigned __int128 with floating types (docs/notes/pathb-int128.md): conversions both ways for float, double
// and long double, truncation toward zero, the rounding of large values, and the comparisons of mixed operands. The
// floating results are printed as their bytes, so they are compared exactly with the gcc backend.
// STDOUT: same
// EXPECT: 0
#include <cstdio>
#include <cstring>

typedef __int128 i128;
typedef unsigned __int128 u128;

static void pr(const char *tag, u128 v) {
  std::printf("%s %016llx%016llx\n", tag, (unsigned long long)(v >> 64), (unsigned long long)v);
}
static void prs(const char *tag, i128 v) { pr(tag, (u128)v); }
static void prld(const char *tag, long double x) {
  unsigned char b[16];
  std::memset(b, 0, sizeof b);
  std::memcpy(b, &x, 10);
  std::printf("%s ", tag);
  for (int i = 9; i >= 0; i--) std::printf("%02x", b[i]);
  std::printf("\n");
}
static void prd(const char *tag, double x) {
  unsigned long long u;
  std::memcpy(&u, &x, sizeof u);
  std::printf("%s %016llx\n", tag, u);
}
static void prf(const char *tag, float x) {
  unsigned int u;
  std::memcpy(&u, &x, sizeof u);
  std::printf("%s %08x\n", tag, u);
}

static volatile double vd = 1.0;
static volatile float vf = 1.0f;
static volatile long double vl = 1.0L;

int main() {
  // integer to floating
  i128 big = (i128)0x123456789abcdef0LL * (i128)0x1000000LL + 0x7f;
  i128 neg = -big - 12345;
  u128 ubig = ((u128)1 << 127) + ((u128)1 << 70) + 3;
  prd("d-big", (double)big);
  prd("d-neg", (double)neg);
  prf("f-big", (float)big);
  prf("f-neg", (float)neg);
  prld("ld-big", (long double)big);
  prld("ld-neg", (long double)neg);
  prd("d-ubig", (double)ubig);
  prf("f-ubig", (float)ubig);
  prld("ld-ubig", (long double)ubig);
  prld("ld-umax", (long double)~(u128)0);
  prld("ld-smin", (long double)((i128)-1 << 127));
  prd("d-one", (double)(i128)1);
  prd("d-zero", (double)(u128)0);

  // floating to integer (in range), truncation toward zero
  double dv = 123456789012345678901234.75 * vd;
  double nd = -dv * vd;
  prs("i-d", (i128)dv);
  prs("i-nd", (i128)nd);
  pr("u-d", (u128)dv);
  prs("i-half", (i128)(-0.5 * vd));
  prs("i-two", (i128)(2.9 * vd));
  prs("i-mtwo", (i128)(-2.9 * vd));
  float fv = 1.5e30f * vf;
  prs("i-f", (i128)fv);
  pr("u-f", (u128)(fv * 3.0f));
  long double lv = 1.0e35L * vl;
  prs("i-ld", (i128)lv);
  pr("u-ld", (u128)(lv * 3.0L));
  prs("i-ld-neg", (i128)(-lv));
  prs("i-ld-small", (i128)(vl * 7.75L));
  prs("i-ld-min", (i128)(-(long double)((u128)1 << 127) * vl));
  pr("u-ld-max", (u128)((long double)((u128)1 << 127) * 1.5L * vl));
  std::printf("bool-d %d %d\n", (int)(bool)(dv * vd), (int)(bool)(0.0 * vd));

  // integer and floating comparisons go through the common type
  std::printf("cmp-d %d %d %d\n", big < 1e30 * vd, (u128)dv == dv, (i128)dv > 0);
  std::printf("cmp-ld %d %d\n", ((long double)big) < vl * 1e40L, (unsigned)(i128)(vl * 5) == 5u);

  // compound assignment converting to and from floating types
  i128 acc = 1000;
  acc += 2.5 * vd;
  prs("acc-d", acc);
  acc *= 1e10 * vd;
  prs("acc-m", acc);
  u128 uacc = 7;
  uacc /= 2 * vf;
  pr("uacc", uacc);
  double dd = 0;
  dd += (i128)12345 * vd;
  prd("dd", dd);
  long double ll = (u128)3;
  ll /= 4 * vl;
  prld("ll", ll);

  // from floating with a conversion to a narrower integer
  std::printf("narrow %d %u\n", (int)(i128)(-7.9 * vd), (unsigned)(u128)(4294967301.5 * vd));
  return 0;
}
