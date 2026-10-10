/* Path B support library for `long double` (docs/notes/pathb-longdouble.md).

   QBE has no 80-bit type, so Path B (be/nfcxx_ir.c) keeps every `long double` value in a 16-byte, 16-aligned memory
   object, in the x86-64 System V layout (the x87 extended format in the low 10 bytes; libc, libm and libstdc++ read and
   write the same bytes), and turns each operation on one into a call of a function in this file. The functions are
   compiled by gcc, which does the arithmetic with the x87 unit itself, so results are bit for bit those of a program
   built by gcc; the "soft" part is only that the compiler back end never sees the type.

   Calling convention of the helpers: results are written through the first parameter (a pointer to a 16-byte object, the
   unused 6 bytes zeroed), operands are passed by pointer, predicates and integer results are returned in eax/rax,
   float and double travel in xmm registers. None of this is visible to other code.

   Build: scripts/pathb-ldrt (gcc -O2 -c, archived as libnfcxxld.a, linked by every Path B link step). */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef long double ld;

#define PUT(d, v) do { ld pv_ = (v); memset((d), 0, 16); *(d) = pv_; } while (0)

void __nfcxx_ld_add(ld *d, const ld *a, const ld *b) { PUT(d, *a + *b); }
void __nfcxx_ld_sub(ld *d, const ld *a, const ld *b) { PUT(d, *a - *b); }
void __nfcxx_ld_mul(ld *d, const ld *a, const ld *b) { PUT(d, *a * *b); }
void __nfcxx_ld_div(ld *d, const ld *a, const ld *b) { PUT(d, *a / *b); }
void __nfcxx_ld_neg(ld *d, const ld *a) { PUT(d, -*a); }

int __nfcxx_ld_eq(const ld *a, const ld *b) { return *a == *b; }
int __nfcxx_ld_ne(const ld *a, const ld *b) { return *a != *b; }
int __nfcxx_ld_lt(const ld *a, const ld *b) { return *a < *b; }
int __nfcxx_ld_le(const ld *a, const ld *b) { return *a <= *b; }
int __nfcxx_ld_gt(const ld *a, const ld *b) { return *a > *b; }
int __nfcxx_ld_ge(const ld *a, const ld *b) { return *a >= *b; }
/* the value as a condition (!= 0; a NaN is true) */
int __nfcxx_ld_nz(const ld *a) { return *a != 0; }

void __nfcxx_ld_from_s64(ld *d, long v) { PUT(d, (ld)v); }
void __nfcxx_ld_from_u64(ld *d, unsigned long v) { PUT(d, (ld)v); }
void __nfcxx_ld_from_f32(ld *d, float v) { PUT(d, (ld)v); }
void __nfcxx_ld_from_f64(ld *d, double v) { PUT(d, (ld)v); }
float __nfcxx_ld_to_f32(const ld *a) { return (float)*a; }
double __nfcxx_ld_to_f64(const ld *a) { return (double)*a; }

/* Checked conversion to an integer type of BITS bits, like the `cf2i` operation of the IR on float and double: it traps
   (abort) on a NaN and when the truncated value does not fit. */
long __nfcxx_ld_to_s(const ld *a, int bits)
{
  ld t = truncl(*a);
  ld hi = ldexpl(1.0L, bits - 1);
  if (!(t >= -hi && t < hi)) abort();
  return (long)t;
}

unsigned long __nfcxx_ld_to_u(const ld *a, int bits)
{
  ld t = truncl(*a);
  ld hi = ldexpl(1.0L, bits);
  if (!(t >= 0 && t < hi)) abort();
  return (unsigned long)t;
}

/* va_arg(ap, long double): the argument is 16 bytes in the overflow area. AP is the address of the __va_list_tag. */
void __nfcxx_ld_vaarg(ld *d, va_list ap) { PUT(d, va_arg(ap, ld)); }

/* __builtin_fpclassify(nan, inf, normal, subnormal, zero, x) with the values of <math.h>'s constants. */
int __nfcxx_ld_fpclassify(const ld *a) { return fpclassify(*a); }
int __nfcxx_ld_isnormal(const ld *a) { return isnormal(*a); }
int __nfcxx_ld_isunordered(const ld *a, const ld *b) { return isunordered(*a, *b); }

/* ---- __int128 and unsigned __int128 (docs/notes/pathb-int128.md) ----

   The same scheme as long double: a 128-bit integer is a 16-byte object in memory, and every operation on one is a call
   of a function here, compiled by gcc. The arithmetic is gcc's own: `a / b` on __int128 is a call of libgcc's __divti3
   (a zero divisor traps there, as in a program built by gcc), a conversion to or from a floating type is the libgcc
   conversion, and the wrapping of + - * is the two's complement one. Operands are pointers to the objects; a result is
   written through the first pointer (all 16 bytes); predicates return int; the checked conversions from a floating type
   abort on a NaN or a value that does not fit, like the IR's cf2i on the other integer types. Objects are read and written
   with memcpy, so no alignment is assumed of them. Build: the same archive (scripts/pathb-ldrt). */
typedef unsigned __int128 u128;
typedef __int128 s128;

static u128 i128_rd(const void *p) { u128 v; memcpy(&v, p, sizeof v); return v; }
static void i128_wr(void *p, u128 v) { memcpy(p, &v, sizeof v); }
#define I128_BIN(name, expr) void __nfcxx_i128_##name(void *d, const void *a, const void *b) { \
  u128 x = i128_rd(a), y = i128_rd(b); (void)x; (void)y; i128_wr(d, (expr)); }

I128_BIN(add, x + y)
I128_BIN(sub, x - y)
I128_BIN(mul, x * y)
I128_BIN(and, x & y)
I128_BIN(or, x | y)
I128_BIN(xor, x ^ y)
I128_BIN(div_s, (u128)((s128)x / (s128)y))
I128_BIN(rem_s, (u128)((s128)x % (s128)y))
I128_BIN(div_u, x / y)
I128_BIN(rem_u, x % y)

void __nfcxx_i128_neg(void *d, const void *a) { i128_wr(d, -i128_rd(a)); }
void __nfcxx_i128_not(void *d, const void *a) { i128_wr(d, ~i128_rd(a)); }

/* shifts: a count outside 0 .. 127 aborts (the IR's cshl and cshr rule) */
static void i128_check_count(long n) { if (n < 0 || n > 127) abort(); }
void __nfcxx_i128_shl(void *d, const void *a, long n) { i128_check_count(n); i128_wr(d, i128_rd(a) << n); }
void __nfcxx_i128_shr_s(void *d, const void *a, long n) { i128_check_count(n); i128_wr(d, (u128)((s128)i128_rd(a) >> n)); }
void __nfcxx_i128_shr_u(void *d, const void *a, long n) { i128_check_count(n); i128_wr(d, i128_rd(a) >> n); }

/* the count of a shift given as a 128-bit value: -1 when it does not fit a long (the count check then aborts) */
long __nfcxx_i128_count(const void *a)
{
  s128 v = (s128)i128_rd(a);
  if (v < 0 || v > (s128)((unsigned long)-1 >> 1)) return -1;
  return (long)v;
}

int __nfcxx_i128_eq(const void *a, const void *b) { return i128_rd(a) == i128_rd(b); }
int __nfcxx_i128_ne(const void *a, const void *b) { return i128_rd(a) != i128_rd(b); }
int __nfcxx_i128_lt_s(const void *a, const void *b) { return (s128)i128_rd(a) < (s128)i128_rd(b); }
int __nfcxx_i128_le_s(const void *a, const void *b) { return (s128)i128_rd(a) <= (s128)i128_rd(b); }
int __nfcxx_i128_lt_u(const void *a, const void *b) { return i128_rd(a) < i128_rd(b); }
int __nfcxx_i128_le_u(const void *a, const void *b) { return i128_rd(a) <= i128_rd(b); }
int __nfcxx_i128_nz(const void *a) { return i128_rd(a) != 0; }

void __nfcxx_i128_from_s64(void *d, long v) { i128_wr(d, (u128)(s128)v); }
void __nfcxx_i128_from_u64(void *d, unsigned long v) { i128_wr(d, (u128)v); }
/* the low 64 bits (a conversion to a narrower integer type is the IR's iconv of this) */
unsigned long __nfcxx_i128_lo64(const void *a) { return (unsigned long)i128_rd(a); }

/* conversions to floating types: the libgcc ones (__floattidf, __floatuntidf, __floattixf, __floatuntixf, ...) */
float __nfcxx_i128_to_f32_s(const void *a) { return (float)(s128)i128_rd(a); }
float __nfcxx_i128_to_f32_u(const void *a) { return (float)i128_rd(a); }
double __nfcxx_i128_to_f64_s(const void *a) { return (double)(s128)i128_rd(a); }
double __nfcxx_i128_to_f64_u(const void *a) { return (double)i128_rd(a); }
void __nfcxx_i128_to_ld_s(void *d, const void *a)
{
  ld v = (ld)(s128)i128_rd(a);
  memset(d, 0, 16);
  memcpy(d, &v, 10);
}
void __nfcxx_i128_to_ld_u(void *d, const void *a)
{
  ld v = (ld)i128_rd(a);
  memset(d, 0, 16);
  memcpy(d, &v, 10);
}

/* conversions from floating types, truncating toward zero; a NaN or a value outside the type aborts. The bounds are
   the powers of two 2^127 (signed) and 2^128 (unsigned), exact in long double. */
static void i128_from_ld(void *d, ld x, int sgn)
{
  ld t = truncl(x);
  ld lim = ldexpl(1.0L, sgn ? 127 : 128);
  if (sgn) {
    if (!(t >= -lim && t < lim)) abort();
    i128_wr(d, (u128)(s128)t);
  } else {
    if (!(t >= 0 && t < lim)) abort();
    i128_wr(d, (u128)t);
  }
}
void __nfcxx_i128_from_f32_s(void *d, float x) { i128_from_ld(d, (ld)x, 1); }
void __nfcxx_i128_from_f32_u(void *d, float x) { i128_from_ld(d, (ld)x, 0); }
void __nfcxx_i128_from_f64_s(void *d, double x) { i128_from_ld(d, (ld)x, 1); }
void __nfcxx_i128_from_f64_u(void *d, double x) { i128_from_ld(d, (ld)x, 0); }
void __nfcxx_i128_from_ld_s(void *d, const void *a)
{
  ld x = 0;
  memcpy(&x, a, 10);
  i128_from_ld(d, x, 1);
}
void __nfcxx_i128_from_ld_u(void *d, const void *a)
{
  ld x = 0;
  memcpy(&x, a, 10);
  i128_from_ld(d, x, 0);
}

/* Bit-fields of 128-bit type: the field is bits off .. off+width-1 of the object at base (bit 0 is the lowest bit of
   base[0]); bfget extracts it (sign-extended when sgn), bfset replaces it with the low width bits of *val. */
void __nfcxx_i128_bfget(void *d, const unsigned char *base, unsigned long off, int width, int sgn)
{
  u128 v = 0;
  int i;
  for (i = 0; i < width; i++) {
    unsigned long b = off + (unsigned long)i;
    if ((base[b >> 3] >> (b & 7)) & 1) v |= (u128)1 << i;
  }
  if (sgn && width > 0 && width < 128 && ((v >> (width - 1)) & 1)) v |= ~(u128)0 << width;
  i128_wr(d, v);
}
void __nfcxx_i128_bfset(unsigned char *base, unsigned long off, int width, const void *val)
{
  u128 v = i128_rd(val);
  int i;
  for (i = 0; i < width; i++) {
    unsigned long b = off + (unsigned long)i;
    unsigned char m = (unsigned char)(1u << (b & 7));
    if ((v >> i) & 1) base[b >> 3] |= m;
    else base[b >> 3] &= (unsigned char)~m;
  }
}
