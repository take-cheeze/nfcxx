// __int128 in control flow and library code on Path B (docs/notes/pathb-int128.md): switch on a 128-bit value (labels that
// fit a long, negative labels, values outside the 64-bit range that must reach default, fallthrough, a nested switch on an
// int), exceptions carrying a 128-bit value, variadic calls passing one, std::function and std::sort.
// STDOUT: same
// EXPECT: 0
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <vector>

typedef __int128 i128;
typedef unsigned __int128 u128;

int sw(i128 v) {
  switch (v) {
    case 3: return 30;
    case 5: return 50;
    case -7: return -70;
    default: return -1;
  }
}

int sw_fall(u128 v, int k) {
  int r = 0;
  switch (v) {
    case 0:
      r += 1;
      [[fallthrough]];
    case 1:
      r += 10;
      break;
    case 0x7fffffffffffffffULL:
      switch (k) {
        case 2: r = 100; break;
        default: r = 200;
      }
      break;
    default:
      r = 1000;
  }
  return r;
}

int thr(int k) {
  try {
    if (k) throw (i128)k * 1000000000000000000LL;
  } catch (i128 x) {
    return (int)(x / 1000000000000000000LL);
  }
  return 0;
}

int vsum(int n, ...) {
  va_list ap;
  va_start(ap, n);
  int r = 0;
  for (int i = 0; i < n; i++) r += va_arg(ap, int);
  va_end(ap);
  return r;
}

int pass_var(i128 v) { return vsum(1, (int)v) + vsum(0, v); }

int main() {
  std::printf("sw %d %d %d %d\n", sw(3), sw(5), sw(-7), sw(7));
  std::printf("sw-big %d %d\n", sw((i128)1 << 64 | 3), sw(-((i128)1 << 100) + 5));
  std::printf("fall %d %d %d %d\n", sw_fall(0, 0), sw_fall(1, 0), sw_fall((u128)0x7fffffffffffffffULL, 2),
              sw_fall(((u128)1 << 64) | 1, 3));
  std::printf("fall2 %d %d\n", sw_fall((u128)0x7fffffffffffffffULL, 9), sw_fall(~(u128)0 >> 64, 2));
  std::printf("thr %d %d\n", thr(0), thr(4));
  std::printf("var %d\n", pass_var(9));
  std::function<u128(u128)> f = [](u128 x) { return x * 3; };
  std::printf("fn %d\n", (int)f(7));
  std::vector<i128> v = {5, -2, 9, 1};
  std::sort(v.begin(), v.end());
  std::printf("sort %d %d\n", (int)v[0], (int)v[3]);
  return 0;
}
