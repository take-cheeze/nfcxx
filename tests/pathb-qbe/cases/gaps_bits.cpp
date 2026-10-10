// EXPECT: 0
// STDOUT: same
// __builtin_bswap16/32/64, popcount, clz, ctz, ffs, parity, clrsb (int, long and long long forms), expect, unreachable (in a
// branch not taken), assume_aligned, constant_p, object_size, prefetch, launder, is_constant_evaluated. They are expanded
// inline (no libgcc call). Differential: hashes over boundary values and a pseudo-random walk must equal the gcc backend's.
#include <cstdint>
#include <cstdio>
#include <new>
#include <type_traits>

typedef unsigned long long u64;
static u64 mix(u64 h, u64 v) { return (h ^ v) * 1099511628211ULL + 0x9e3779b97f4a7c15ULL; }

static unsigned long long state = 0x243f6a8885a308d3ULL;
static u64 next() {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

int main() {
  u64 h32 = 1, h64 = 1, hs = 1, hb = 1;
  const u64 fixed[] = {0, 1, 2, 3, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fffffffULL, 0x80000000ULL, 0xffffffffULL,
                       0x100000000ULL, 0x7fffffffffffffffULL, 0x8000000000000000ULL, 0xffffffffffffffffULL, 0x0123456789abcdefULL};
  for (int round = 0; round < 3000; round++) {
    u64 x = round < (int)(sizeof fixed / sizeof fixed[0]) ? fixed[round] : (next() >> (next() % 64));
    unsigned u = (unsigned)x;
    unsigned long ul = (unsigned long)x;
    int s = (int)x;
    long sl = (long)x;
    h64 = mix(h64, (u64)__builtin_bswap64(x));
    h32 = mix(h32, __builtin_bswap32(u));
    h32 = mix(h32, __builtin_bswap16((uint16_t)x));
    h32 = mix(h32, __builtin_popcount(u));
    h64 = mix(h64, __builtin_popcountl(ul));
    h64 = mix(h64, __builtin_popcountll(x));
    h32 = mix(h32, __builtin_parity(u));
    h64 = mix(h64, __builtin_parityl(ul));
    h64 = mix(h64, __builtin_parityll(x));
    hs = mix(hs, __builtin_clrsb(s));
    hs = mix(hs, __builtin_clrsbl(sl));
    hs = mix(hs, __builtin_clrsbll((long long)x));
    hs = mix(hs, __builtin_ffs(s));
    hs = mix(hs, __builtin_ffsl(sl));
    hs = mix(hs, __builtin_ffsll((long long)x));
    if (u != 0) {   // clz / ctz of 0 are undefined
      hb = mix(hb, __builtin_clz(u));
      hb = mix(hb, __builtin_ctz(u));
    }
    if (ul != 0) {
      hb = mix(hb, __builtin_clzl(ul));
      hb = mix(hb, __builtin_ctzl(ul));
      hb = mix(hb, __builtin_clzll(x));
      hb = mix(hb, __builtin_ctzll(x));
    }
  }
  std::printf("%llx %llx %llx %llx\n", h32, h64, hs, hb);

  int r = 0;
  volatile unsigned short v16 = 0xabcd;
  if (__builtin_bswap16(v16) != 0xcdab) r |= 1;
  int local = 0;
  int *q = (int *)__builtin_assume_aligned(&local, 4);
  if (q != &local) r |= 2;
  // (gcc may know the size of a visible object; for a pointer it cannot trace the answer is the documented unknown)
  void *volatile unknown = &local;
  if (__builtin_object_size(unknown, 0) != (unsigned long)-1 || __builtin_object_size(unknown, 3) != 0) r |= 4;
  if (!__builtin_expect(r == 0, 1)) r |= 8;
  if (__builtin_expect_with_probability(r, 0, 0.5) != r) r |= 16;
  __builtin_prefetch(&local);
  __builtin_prefetch(&local, 1, 0);
  if (__builtin_launder(q) != q) r |= 32;
  if (std::is_constant_evaluated()) r |= 64;
  if (r != 0 && __builtin_constant_p(r) && false) __builtin_unreachable();
  std::printf("misc %d\n", r);
  return r;
}
