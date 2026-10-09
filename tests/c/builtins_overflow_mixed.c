/* EXPECT: 0 */
/* __builtin_{add,sub,mul}_overflow with operands and result of different types: the exact result is converted
   to *r (wrapping) and the flag says whether it changed. Expected values are what GCC gives. */
#include <limits.h>
int main(void) {
  int bad = 0;
  { int x = 1; long r; if (__builtin_add_overflow(x, x, &r) || r != 2) bad |= 1; }            /* int operands, long result */
  { int x = INT_MAX; long r; if (__builtin_add_overflow(x, x, &r) || r != 4294967294L) bad |= 2; }
  { long x = -1; unsigned long r; if (!__builtin_add_overflow(x, 0, &r) || r != ULONG_MAX) bad |= 4; }   /* negative into unsigned */
  { unsigned x = 3; int y = -5; int r; if (__builtin_add_overflow(x, y, &r) || r != -2) bad |= 8; }
  { unsigned x = 3; int y = -5; unsigned r; if (!__builtin_add_overflow(x, y, &r) || r != 4294967294u) bad |= 16; }
  { unsigned long x = ULONG_MAX; int y = 1; unsigned long r; if (!__builtin_add_overflow(x, y, &r) || r != 0) bad |= 32; }
  { unsigned long x = ULONG_MAX; long y = -1; unsigned long r; if (__builtin_add_overflow(x, y, &r) || r != ULONG_MAX - 1) bad |= 64; }
  { unsigned long x = 5; long y = 7; long r; if (__builtin_sub_overflow(x, y, &r) || r != -2) bad |= 128; }
  { unsigned long x = 5; long y = 7; unsigned long r; if (!__builtin_sub_overflow(x, y, &r) || r != ULONG_MAX - 1) bad |= 256; }
  { unsigned long x = ULONG_MAX; long y = 0; long r; if (!__builtin_sub_overflow(x, y, &r) || r != -1) bad |= 512; }
  { long x = LONG_MIN; unsigned long y = 1UL << 63; long r; if (__builtin_add_overflow(x, y, &r) || r != 0) bad |= 1024; }
  { int x = 70000; int y = 70000; long r; if (__builtin_mul_overflow(x, y, &r) || r != 4900000000L) bad |= 2048; }
  { int x = 70000; int y = 70000; int r; if (!__builtin_mul_overflow(x, y, &r) || r != 605032704) bad |= 4096; }
  { long x = -3; unsigned long y = 4; long r; if (__builtin_mul_overflow(x, y, &r) || r != -12) bad |= 8192; }
  { long x = -3; unsigned long y = 4; unsigned long r; if (!__builtin_mul_overflow(x, y, &r) || r != ULONG_MAX - 11) bad |= 16384; }
  { unsigned long x = 1UL << 63; int y = 2; unsigned long r; if (!__builtin_mul_overflow(x, y, &r) || r != 0) bad |= 32768; }
  { unsigned long x = 1UL << 40; long y = -(1L << 23); long r; if (__builtin_mul_overflow(x, y, &r) || r != LONG_MIN) bad |= 65536; }
  { unsigned long x = 1UL << 40; long y = -(1L << 24); long r; if (!__builtin_mul_overflow(x, y, &r) || r != 0) bad |= 131072; }
  { unsigned long x = 0xffffffffUL; unsigned long y = 0xffffffffUL; unsigned long r; if (__builtin_mul_overflow(x, y, &r) || r != 0xfffffffe00000001UL) bad |= 262144; }
  { char c = 100; signed char r; if (!__builtin_add_overflow(c, c, &r) || r != -56) bad |= 524288; }          /* char/short results */
  { int x = 200; unsigned char r; if (__builtin_add_overflow(x, 55, &r) || r != 255) bad |= 1048576; }
  { int x = 200; unsigned char r; if (!__builtin_add_overflow(x, 56, &r) || r != 0) bad |= 2097152; }
  { unsigned short s = 65535; short r; if (!__builtin_sub_overflow(s, -1, &r) || r != 0) bad |= 4194304; }
  { long x = LONG_MAX; int r; if (!__builtin_add_overflow(x, 1, &r) || r != 0) bad |= 8388608; }              /* literal operand, narrower result */
  { int x = 5; long long r; if (__builtin_add_overflow(x, 3000000000L, &r) || r != 3000000005LL) bad |= 16777216; }
  { int r; if (__builtin_sub_overflow(0, 0, &r) || r != 0) bad |= 33554432; }
  return bad == 0 ? 0 : (bad & 127) ? (bad & 127) : 99;
}
