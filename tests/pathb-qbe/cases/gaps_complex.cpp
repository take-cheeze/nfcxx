// EXPECT: 0
// GCC: undefined
// std::complex<double> arithmetic and the C99 complex built-ins it uses (__builtin_cabs, carg, csqrt, cexp, ...: libm calls with
// a _Complex argument, which the System V ABI passes like a struct of two doubles). The gcc backend cannot link them
// (undefined reference to __builtin_cabs), so only the exit status is checked, against hand-computed values.
#include <cmath>
#include <complex>
#include <cstdio>

static bool close(double a, double b) { return std::fabs(a - b) < 1e-9; }

int main() {
  std::complex<double> z(3, 4), w(1, -2);
  auto p = z * w;
  int r = 0;
  if (!close(p.real(), 11) || !close(p.imag(), -2)) r |= 1;
  if (!close(std::abs(z), 5.0)) r |= 2;
  if (!close(std::arg(w), -1.1071487177940904)) r |= 4;
  auto s = std::sqrt(z);
  if (!close(s.real(), 2.0) || !close(s.imag(), 1.0)) r |= 8;
  auto q = z / w;
  if (!close(q.real(), -1.0) || !close(q.imag(), 2.0)) r |= 16;
  auto e = std::exp(std::complex<double>(0, M_PI));
  if (!close(e.real(), -1.0) || !close(e.imag(), 0.0)) r |= 32;
  if (!close(std::norm(z), 25.0) || std::conj(z) != std::complex<double>(3, -4)) r |= 64;
  auto pw = std::pow(z, 2);
  if (!close(pw.real(), -7.0) || !close(pw.imag(), 24.0)) r |= 128;
  std::printf("%d\n", r);
  return r;
}
