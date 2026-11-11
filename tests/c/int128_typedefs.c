// EXPECT: 0
// __uint128_t and __int128_t are builtin typedefs of gcc and clang. The qbe backend names cproc's __int128 for them on every
// target (scripts/qbe-cc); a 128-bit product and shift gives the same answer as gcc's.
static unsigned long hi(unsigned long a, unsigned long b) {
  const __uint128_t x = ((__uint128_t)a << 32) | b;
  const __uint128_t m = ((__uint128_t)1 << 53) | 1;
  return (unsigned long)((x * m) >> 64);
}
static long sgn(long a, long b) { const __int128_t p = (__int128_t)a * b; return (long)(p >> 70); }
int main(void) {
  if (hi(0x12345678ul, 0x9abcdef0ul) != 0x2468acf13579bul) return 1;
  if (sgn(-0x7fffffffffffffffl, 0x7fffffffffffffffl) != -72057594037927936l || sgn(0x4000000000000000l, 8) != 0) return 2;
  return 0;
}
