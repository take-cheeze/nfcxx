/* The C side of multi/abi_i128: built by the host C compiler. __int128 is passed and returned in the integer registers
   (rax:rdx for a result), a struct of one __int128 likewise, and a struct of 32 bytes in memory: the same convention Path B
   uses for the type (docs/notes/pathb-int128.md). */
typedef __int128 i128;
typedef unsigned __int128 u128;

struct pair16 { i128 v; };
struct big { i128 a; u128 b; long c; };

i128 c_add4(i128 a, i128 b, i128 c, i128 d) { return a + b * 2 - c + d * 3; }
u128 c_udiv(u128 a, u128 b) { return a / b; }
struct pair16 c_wrap(struct pair16 p, int k) { p.v = p.v * k; return p; }
struct big c_big(struct big b) { b.a = -b.a; b.b += 1; b.c++; return b; }

/* calls into Path B (in a.cpp) */
i128 cpp_mix(i128 a, unsigned long k, i128 b, int c, i128 d, i128 e, u128 f);
struct pair16 cpp_pair(struct pair16 p, long k);
struct big cpp_big(struct big b);

int c_check(void)
{
  int fails = 0;
  struct pair16 p = { 1000 }, q;
  struct big b = { -5, 7, 9 }, r;
  if (cpp_mix(1, 2, 3, 4, 5, 6, 7) != 21) fails++;   /* 1 + 2*2 + 3*4 + 5 - 7 + 6 */
  q = cpp_pair(p, -3);
  if (q.v != -3000) fails++;
  r = cpp_big(b);
  if (r.a != 5 || r.b != 8 || r.c != 10) fails++;
  return fails;
}
