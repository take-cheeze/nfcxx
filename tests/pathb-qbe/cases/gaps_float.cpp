// EXPECT: 0
// STDOUT: same
// Floating-point classification and comparison built-ins as <cmath> uses them (isnan, isinf, isfinite, isnormal, signbit,
// fpclassify, isgreater ..., __builtin_isinf_sign, copysign, fabs), non-finite constants (NAN, INFINITY, HUGE_VAL, quiet and
// signaling NaN from numeric_limits), their propagation through arithmetic, and the printf of them.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>

static volatile double zero = 0.0;

int main() {
  volatile double d = 1.5, nan = NAN, inf = INFINITY, sub = 4.9e-324, big = 1e308;
  volatile float f = -2.f, fnan = std::numeric_limits<float>::quiet_NaN(), finf = std::numeric_limits<float>::infinity();
  int r = 0;
  if (std::isnan(d) || !std::isnan(nan) || !std::isnan(fnan) || std::isnan(f)) r |= 1;
  if (std::isinf(d) || !std::isinf(inf) || !std::isinf(-inf) || !std::isinf(finf) || std::isinf(nan)) r |= 2;
  if (!std::isfinite(d) || std::isfinite(inf) || std::isfinite(nan) || !std::isfinite(sub)) r |= 4;
  if (std::signbit(d) || !std::signbit(f) || !std::signbit(-0.0 * d) || std::signbit(zero)) r |= 8;
  if (!std::isnormal(d) || std::isnormal(sub) || std::isnormal(zero) || std::isnormal(inf) || std::isnormal(nan)) r |= 16;
  if (std::fpclassify(d) != FP_NORMAL || std::fpclassify(sub) != FP_SUBNORMAL || std::fpclassify(zero) != FP_ZERO ||
      std::fpclassify(inf) != FP_INFINITE || std::fpclassify(nan) != FP_NAN || std::fpclassify(f) != FP_NORMAL) r |= 32;
  if (!std::isgreater(d, 1.0) || std::isless(d, 1.0) || !std::islessgreater(d, 2.0) || std::islessgreater(d, d) ||
      !std::isgreaterequal(d, d) || !std::islessequal(d, 2.0)) r |= 64;
  if (!std::isunordered(d, nan) || std::isunordered(d, d) || std::isgreater(nan, d) || std::isless(d, nan)) r |= 128;
  if (__builtin_isinf_sign(-inf) != -1 || __builtin_isinf_sign(inf) != 1 || __builtin_isinf_sign(d) != 0) r |= 256;
  if (std::fabs(f) != 2.f || std::sqrt(4.0) != 2.0 || std::floor(d) != 1.0 || std::ceil(d) != 2.0) r |= 512;
  if (__builtin_copysign(1.0, -0.0) != -1.0 || std::copysign(3.0, -1.0) != -3.0) r |= 1024;
  if (!(inf > big) || !(-inf < -big) || (nan == nan) || !(nan != nan) || (nan < 1) || (nan > 1)) r |= 2048;
  if (!std::isnan(inf - inf) || !std::isnan(inf * zero) || !std::isnan(zero / zero) || std::isinf(big * 10) == 0) r |= 4096;
  if (std::numeric_limits<double>::infinity() != inf || std::numeric_limits<double>::max() != 1.7976931348623157e308 ||
      std::numeric_limits<double>::denorm_min() != sub || std::numeric_limits<float>::epsilon() != 1.1920929e-7f) r |= 8192;
  // unions of the bit patterns
  unsigned long long bits;
  double q = nan;
  std::memcpy(&bits, (const void *)&q, sizeof bits);
  if ((bits >> 52 & 0x7ff) != 0x7ff || (bits & 0xfffffffffffffULL) == 0) r |= 16384;
  q = inf;
  std::memcpy(&bits, (const void *)&q, sizeof bits);
  if (bits != 0x7ff0000000000000ULL) r |= 32768;
  std::printf("%g %g %g %f %e %g %g\n", (double)inf, (double)-inf, (double)nan, (double)inf, (double)-inf, (double)finf, (double)sub);
  std::printf("%d %d %d %d\n", std::isnan(std::nan("")), std::isinf(HUGE_VAL), std::isnan(std::sqrt(-1.0)), std::isinf(std::log(0.0)));
  std::printf("%d\n", r);
  return r;
}
