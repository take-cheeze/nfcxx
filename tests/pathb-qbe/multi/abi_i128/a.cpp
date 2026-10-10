// __int128 across the C boundary (docs/notes/pathb-int128.md): Path B and the host C compiler (c.c) exchange 128-bit
// integers as arguments (in two integer registers each, the fourth on the stack), results (rax:rdx), a struct of one
// __int128 and a 32-byte struct in memory. The C side is built by cc (c.c), this side by the Path B pipeline.
// EXPECT: 0
#include <cstdio>

typedef __int128 i128;
typedef unsigned __int128 u128;

extern "C" {
struct pair16 { i128 v; };
struct big { i128 a; u128 b; long c; };

i128 c_add4(i128 a, i128 b, i128 c, i128 d);
u128 c_udiv(u128 a, u128 b);
struct pair16 c_wrap(struct pair16 p, int k);
struct big c_big(struct big b);
int c_check(void);

i128 cpp_mix(i128 a, unsigned long k, i128 b, int c, i128 d, i128 e, u128 f) {
  return a + (i128)k * 2 + b * c + d - (i128)f + e;
}
struct pair16 cpp_pair(struct pair16 p, long k) {
  p.v = p.v * k;
  return p;
}
struct big cpp_big(struct big b) {
  b.a = -b.a;
  b.b += 1;
  b.c++;
  return b;
}
}

int main() {
  int fails = 0;
  i128 s = c_add4(1, 2, 3, -4);
  if (s != 1 + 4 - 3 - 12) fails++;
  if (c_udiv(((u128)1 << 100) + 7, 3) != (((u128)1 << 100) + 7) / 3) fails++;
  struct pair16 p = { (i128)-70000 }, q = c_wrap(p, 3);
  if (q.v != (i128)-210000) fails++;
  struct big b = { (i128)1 << 90, 5, 7 }, r = c_big(b);
  if (r.a != -((i128)1 << 90) || r.b != 6 || r.c != 8) fails++;
  if (c_check() != 0) fails++;
  std::printf("fails %d\n", fails);
  return fails;
}
