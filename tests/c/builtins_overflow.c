/* EXPECT: 0 */
/* Type-generic __builtin_{add,sub,mul}_overflow and the popcount/ctz/clz builtins (cproc has none of them;
   scripts/qbe-prep.py lowers them). */
#include <stdio.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
int main(void) {
  long a, b; unsigned long ua; int ia; long long ll; unsigned ui;
  int bad = 0;
  if (__builtin_add_overflow(LONG_MAX, 1L, &a) != 1 || a != LONG_MIN) bad |= 1;
  { long x = 5, y = 7; if (__builtin_add_overflow(x, y, &a) || a != 12) bad |= 2; }
  { long x = LONG_MIN, y = 1; if (__builtin_sub_overflow(x, y, &a) != 1 || a != LONG_MAX) bad |= 4; }
  { long x = LONG_MIN, y = -1; if (__builtin_mul_overflow(x, y, &a) != 1) bad |= 8; }
  { long x = -1, y = LONG_MIN; if (__builtin_mul_overflow(x, y, &a) != 1) bad |= 8; }
  { long x = 3037000500L, y = 3037000500L; if (__builtin_mul_overflow(x, y, &a) != 1) bad |= 16; }
  { long x = 3037000499L, y = 3037000499L; if (__builtin_mul_overflow(x, y, &a) || a != 9223372030926249001L) bad |= 32; }
  { long x = -4, y = 5; if (__builtin_mul_overflow(x, y, &a) || a != -20) bad |= 64; }
  { unsigned long x = ULONG_MAX; if (__builtin_add_overflow(x, 1, &ua) != 1 || ua != 0) bad |= 128; }
  { unsigned long x = 0; if (__builtin_sub_overflow(x, 1UL, &ua) != 1 || ua != ULONG_MAX) bad |= 256; }
  { unsigned long x = 1UL << 40, y = 1UL << 30; if (__builtin_mul_overflow(x, y, &ua) != 1) bad |= 512; }
  { int x = INT_MAX, y = 1; if (__builtin_add_overflow(x, y, &ia) != 1 || ia != INT_MIN) bad |= 1024; }
  { unsigned x = 3, y = 4; if (__builtin_mul_overflow(x, y, &ui) || ui != 12) bad |= 2048; }
  { int64_t x = INT64_MAX; if (!__builtin_add_overflow(x, (int64_t)1, &x) || x != INT64_MIN) bad |= 4096; }
  if (__builtin_popcount(0xf0f0u) != 8 || __builtin_popcountll(~0ULL) != 64 || __builtin_popcountl(5UL) != 2) bad |= 8192;
  if (__builtin_ctz(8u) != 3 || __builtin_ctzll(1ULL << 40) != 40 || __builtin_ctzl(96UL) != 5) bad |= 16384;
  if (__builtin_clz(1u) != 31 || __builtin_clzll(1ULL) != 63 || __builtin_clzl(2UL) != 62) bad |= 32768;
  return bad == 0 ? 0 : (bad & 127) ? (bad & 127) : 99;
}
