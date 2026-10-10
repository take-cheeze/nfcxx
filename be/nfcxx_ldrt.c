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
