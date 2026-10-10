// <cmath> and <cstdlib>/<limits> overloads for long double (docs/notes/pathb-longdouble.md): the std:: functions that
// libstdc++ forwards to the *l functions of libm or to built-ins (fabsl, isnan, signbit, fpclassify, isgreater ...),
// numeric_limits<long double>, and the C++17 special functions.
// EXPECT: 0
// STDOUT: same
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <complex>
#include <numeric>
#include <algorithm>
#include <vector>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

typedef std::numeric_limits<long double> NL;

int main() {
  CHECK(NL::digits == 64 && NL::max_exponent == 16384 && NL::is_iec559 && NL::has_infinity && NL::radix == 2);
  CHECK(NL::epsilon() == 1.0842021724855044340e-19L && NL::min() > 0 && NL::min() < 1e-4931L);
  CHECK(NL::max() > 1e4932L && NL::lowest() == -NL::max() && NL::infinity() > NL::max());
  CHECK(std::isnan(NL::quiet_NaN()) && std::isnan(NL::signaling_NaN()) && !std::isnan(NL::max()));
  CHECK(NL::denorm_min() > 0 && NL::denorm_min() / 2 == 0 && NL::round_error() == 0.5L);
  printf("%La %La %La %La\n", NL::epsilon(), NL::min(), NL::max(), NL::denorm_min());

  long double x = 2.5L, nx = -2.5L, inf = NL::infinity(), nan = NL::quiet_NaN();
  CHECK(std::abs(nx) == x && std::fabs(nx) == x && std::abs(-0.0L) == 0 && !std::signbit(std::abs(-0.0L)));
  CHECK(std::floor(nx) == -3 && std::ceil(nx) == -2 && std::trunc(nx) == -2 && std::round(nx) == -3 && std::nearbyint(x) == 2);
  CHECK(std::rint(3.5L) == 4 && std::lround(nx) == -3 && std::llround(x) == 3 && std::lrint(x) == 2);
  CHECK(std::fmod(7.5L, 2) == 1.5L && std::remainder(7.5L, 2) == -0.5L && std::fdim(5, 3) == 2 && std::fmax(1, nan) == 1);
  CHECK(std::copysign(2.0L, -0.0L) == -2 && std::fmin(1, 2) == 1 && std::hypot(3.0L, 4.0L) == 5);
  CHECK(std::sqrt(2.25L) == 1.5L && std::cbrt(27.0L) == 3 && std::pow(2.0L, 10) == 1024 && std::pow(2.0L, -1) == 0.5L);
  CHECK(std::pow(9.0L, 0.5L) == 3 && std::pow(2, 3.0L) == 8 && std::exp2(10.0L) == 1024 && std::log2(1024.0L) == 10);
  CHECK(std::ldexp(1.5L, 4) == 24 && std::scalbn(3.0L, 2) == 12 && std::ilogb(8.0L) == 3 && std::logb(8.0L) == 3);
  int e; long double m = std::frexp(40.0L, &e);
  CHECK(m == 0.625L && e == 6);
  long double ip; long double fr = std::modf(-3.75L, &ip);
  CHECK(fr == -0.75L && ip == -3);
  int quo; long double rem = std::remquo(10.0L, 3.0L, &quo);
  CHECK(rem == 1 && quo == 3);

  // classification
  CHECK(std::isnan(nan) && !std::isnan(x) && std::isinf(inf) && std::isinf(-inf) && !std::isinf(x));
  CHECK(std::isfinite(x) && !std::isfinite(inf) && !std::isfinite(nan));
  CHECK(std::signbit(nx) && !std::signbit(x) && std::signbit(-0.0L) && std::signbit(-inf));
  CHECK(std::isnormal(x) && !std::isnormal(0.0L) && !std::isnormal(NL::denorm_min()) && !std::isnormal(inf));
  CHECK(std::fpclassify(x) == FP_NORMAL && std::fpclassify(0.0L) == FP_ZERO && std::fpclassify(inf) == FP_INFINITE);
  CHECK(std::fpclassify(nan) == FP_NAN && std::fpclassify(NL::denorm_min()) == FP_SUBNORMAL);
  CHECK(std::isgreater(x, 1.0L) && std::isless(1.0L, x) && std::isgreaterequal(x, x) && std::islessequal(x, x));
  CHECK(!std::isgreater(nan, 1.0L) && !std::isless(nan, 1.0L) && std::isunordered(nan, 1.0L) && !std::isunordered(x, 1.0L));
  CHECK(std::islessgreater(1.0L, x) && !std::islessgreater(x, x) && !std::islessgreater(nan, x));

  // functions printed bit for bit (the results of the C library are the same objects in both builds)
  printf("%La %La %La %La\n", std::sin(1.0L), std::cos(1.0L), std::tan(1.0L), std::atan(1.0L));
  printf("%La %La %La %La\n", std::asin(0.5L), std::acos(0.5L), std::atan2(1.0L, 3.0L), std::exp(1.0L));
  printf("%La %La %La %La\n", std::log(10.0L), std::log10(2.0L), std::log1p(0.25L), std::expm1(0.25L));
  printf("%La %La %La %La\n", std::sinh(1.0L), std::cosh(1.0L), std::tanh(1.0L), std::asinh(1.0L));
  printf("%La %La\n", std::lgamma(5.5L), std::erfc(0.3L));

  // C++17 special functions (templates over long double in <cmath>/<bits/specfun.h>)
  printf("%La %La %La\n", std::legendre(3, 0.5L), std::hermite(4, 0.75L), std::laguerre(2, 1.5L));
  printf("%La %La\n", std::comp_ellint_1(0.5L), std::riemann_zeta(2.0L));

  // numeric algorithms and complex
  std::vector<long double> v{0.1L, 0.2L, 0.3L};
  long double acc = std::accumulate(v.begin(), v.end(), 0.0L);
  long double dot = std::inner_product(v.begin(), v.end(), v.begin(), 0.0L);
  CHECK(acc > 0.599L && acc < 0.601L && dot > 0.139L && dot < 0.141L);
  CHECK(*std::max_element(v.begin(), v.end()) == 0.3L && std::clamp(5.0L, 1.0L, 2.0L) == 2 && std::midpoint(1.0L, 4.0L) == 2.5L);
  std::complex<long double> c(3, 4), d(1, -2);
  CHECK((c * d).real() == 11 && (c * d).imag() == -2 && (c / d).real() == -1 && std::norm(c) == 25);
  CHECK(std::strtold("1e4000", nullptr) > 1e308L && std::hypot(1e300L, 1e300L) > 1.4e300L);
  printf("%d\n", fails);
  return fails;
}
