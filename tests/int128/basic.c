#include <stdio.h>
typedef __int128 i128;
typedef unsigned __int128 u128;
static void pr(const char *tag, u128 v) { printf("%s %016llx%016llx\n", tag, (unsigned long long)(v >> 64), (unsigned long long)v); }
__attribute__((noinline)) i128 mul(i128 a, i128 b) { return a * b; }
int main(void) {
  i128 a = 3, b = -5;
  u128 u = 1;
  pr("a*b", (u128)mul(a, b));
  pr("shl", u << 100);
  pr("u-1", (u128)(u - 2));
  printf("cmp %d %d\n", a > b, (u128)a > (u128)b);
  printf("lo %lld\n", (long long)(a * 7));
  printf("div %lld rem %lld\n", (long long)(b / 2), (long long)(b % 2));
  return 0;
}
