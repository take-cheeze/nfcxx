#include <stdio.h>
#include <string.h>
typedef __int128 i128;
typedef unsigned __int128 u128;
static i128 g1 = 12345678901234567LL;
static u128 g2 = 7;
static i128 garr[3] = {1, -2, 3};
struct S { i128 a; int tag; u128 b; };
static struct S gs = {-9, 4, 11};
static void pr(const char *tag, u128 v) { printf("%s %016llx%016llx\n", tag, (unsigned long long)(v >> 64), (unsigned long long)v); }
__attribute__((noinline)) static i128 addp(i128 x, i128 y, unsigned char c) { return x + y + c; }
__attribute__((noinline)) static u128 retu(void) { return ~(u128)0 >> 3; }
int main(void) {
  volatile double vd = -1234.75; volatile float vf = 3e20f; volatile long double vl = 1e25L;
  volatile unsigned long long vu = 18446744073709551615ULL; volatile long vs = -42;
  i128 x = (i128)vd, y = (i128)vf, z = (i128)vl;
  u128 uu = (u128)vl;
  pr("d2i", (u128)x); pr("f2i", (u128)y); pr("l2i", (u128)z); pr("l2u", uu);
  printf("back %.3f %.3f %.1f\n", (double)x, (double)y, (double)z);
  printf("ufrom %llu sfrom %lld\n", (unsigned long long)(u128)vu, (long long)(i128)vs);
  pr("g1", (u128)g1); pr("g2", g2); printf("garr %lld %lld %lld\n", (long long)garr[0], (long long)garr[1], (long long)garr[2]);
  printf("gs %lld %d %llu\n", (long long)gs.a, gs.tag, (unsigned long long)gs.b);
  pr("addp", (u128)addp(-100, 30, 5));
  pr("retu", retu());
  i128 n = 10; n++; ++n; n--; n += 5; n *= 2; n <<= 3; n >>= 1; n ^= 0xff; n &= ~(i128)1; n |= 4;
  pr("cmp", (u128)n);
  printf("not %d %d\n", !n, !(i128)0);
  i128 m = -1; pr("inv", (u128)~m); pr("neg", (u128)-m);
  u128 sh = 1; sh <<= 127; pr("hi", sh); pr("shrs", (u128)((i128)sh >> 120));
  printf("bool %d %d\n", (int)(sh != 0), (int)(i128)0 ? 1 : 0);
  unsigned char c = 200; char sc = -5; short ss = -300; unsigned int ui = 4000000000u;
  pr("ci", (u128)(i128)c); pr("si", (u128)(i128)sc); pr("ss", (u128)(i128)ss); pr("ui", (u128)(i128)ui);
  printf("trunc %d %u %lld\n", (int)(i128)(0x1234567890LL), (unsigned)(u128)0x1234567890LL, (long long)(i128)(-1));
  printf("cmp2 %d %d %d\n", (i128)-1 < 0, (u128)-1 > 5, (i128)3 >= (i128)3);
  printf("shift-count %lld\n", (long long)((i128)1 << (unsigned char)40));
  return 0;
}
