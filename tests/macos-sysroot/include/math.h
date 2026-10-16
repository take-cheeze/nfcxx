/* Clean-room math.h: declarations from C11 7.12 (Mathematics). Written from the standard, not from any SDK.
 * Compile checks only: the functions are declared, not provided, and nothing is linked. */
#ifndef CLEANROOM_MATH_H
#define CLEANROOM_MATH_H

#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define HUGE_VALL (__builtin_huge_vall())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))

#define FP_INFINITE 1
#define FP_NAN 2
#define FP_NORMAL 3
#define FP_SUBNORMAL 4
#define FP_ZERO 5

#define FP_FAST_FMA 1
#define FP_FAST_FMAF 1
#define FP_FAST_FMAL 1
#define FP_ILOGB0 (-2147483647 - 1)
#define FP_ILOGBNAN (-2147483647 - 1)
#define MATH_ERRNO 1
#define MATH_ERREXCEPT 2
#define math_errhandling (MATH_ERRNO | MATH_ERREXCEPT)

#define fpclassify(x) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, (x))
#define isfinite(x) __builtin_isfinite(x)
#define isinf(x) __builtin_isinf(x)
#define isnan(x) __builtin_isnan(x)
#define isnormal(x) __builtin_isnormal(x)
#define signbit(x) __builtin_signbit(x)
#define isgreater(x, y) __builtin_isgreater((x), (y))
#define isgreaterequal(x, y) __builtin_isgreaterequal((x), (y))
#define isless(x, y) __builtin_isless((x), (y))
#define islessequal(x, y) __builtin_islessequal((x), (y))
#define islessgreater(x, y) __builtin_islessgreater((x), (y))
#define isunordered(x, y) __builtin_isunordered((x), (y))

double acos(double);
double asin(double);
double atan(double);
double atan2(double, double);
double cos(double);
double sin(double);
double tan(double);
double acosh(double);
double asinh(double);
double atanh(double);
double cosh(double);
double sinh(double);
double tanh(double);
double exp(double);
double exp2(double);
double expm1(double);
double frexp(double, int *);
double ldexp(double, int);
double log(double);
double log10(double);
double log2(double);
double log1p(double);
double logb(double);
double modf(double, double *);
double scalbn(double, int);
double scalbln(double, long);
int ilogb(double);
double cbrt(double);
double fabs(double);
double hypot(double, double);
double pow(double, double);
double sqrt(double);
double erf(double);
double erfc(double);
double lgamma(double);
double tgamma(double);
double ceil(double);
double floor(double);
double nearbyint(double);
double rint(double);
long lrint(double);
long long llrint(double);
double round(double);
long lround(double);
long long llround(double);
double trunc(double);
double fmod(double, double);
double remainder(double, double);
double remquo(double, double, int *);
double copysign(double, double);
double nan(const char *);
double nextafter(double, double);
double nexttoward(double, long double);
double fdim(double, double);
double fmax(double, double);
double fmin(double, double);
double fma(double, double, double);

float acosf(float);
float asinf(float);
float atanf(float);
float atan2f(float, float);
float cosf(float);
float sinf(float);
float tanf(float);
float acoshf(float);
float asinhf(float);
float atanhf(float);
float coshf(float);
float sinhf(float);
float tanhf(float);
float expf(float);
float exp2f(float);
float expm1f(float);
float frexpf(float, int *);
float ldexpf(float, int);
float logf(float);
float log10f(float);
float log2f(float);
float log1pf(float);
float logbf(float);
float modff(float, float *);
float scalbnf(float, int);
float scalblnf(float, long);
int ilogbf(float);
float cbrtf(float);
float fabsf(float);
float hypotf(float, float);
float powf(float, float);
float sqrtf(float);
float erff(float);
float erfcf(float);
float lgammaf(float);
float tgammaf(float);
float ceilf(float);
float floorf(float);
float nearbyintf(float);
float rintf(float);
long lrintf(float);
long long llrintf(float);
float roundf(float);
long lroundf(float);
long long llroundf(float);
float truncf(float);
float fmodf(float, float);
float remainderf(float, float);
float remquof(float, float, int *);
float copysignf(float, float);
float nanf(const char *);
float nextafterf(float, float);
float nexttowardf(float, long double);
float fdimf(float, float);
float fmaxf(float, float);
float fminf(float, float);
float fmaf(float, float, float);

long double acosl(long double);
long double asinl(long double);
long double atanl(long double);
long double atan2l(long double, long double);
long double cosl(long double);
long double sinl(long double);
long double tanl(long double);
long double expl(long double);
long double logl(long double);
long double powl(long double, long double);
long double sqrtl(long double);
long double fabsl(long double);
long double floorl(long double);
long double ceill(long double);
long double fmodl(long double, long double);
long double fmal(long double, long double, long double);

#endif
