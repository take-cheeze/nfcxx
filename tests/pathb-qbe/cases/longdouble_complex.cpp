// std::complex<long double> (docs/notes/pathb-longdouble.md): the library functions go to libm's cabsl, cexpl, cpowl ...
// whose _Complex long double arguments are in memory and whose results come back in st(0) and st(1)
// (call thunks, kind callc). EDG's own runtime (__c99_complex_long_double_multiply) returns through a hidden pointer.
// The gcc backend cannot build this one (its C output calls __builtin_cabsl and the like), so only EXPECT is checked.
// GCC: undefined
// EXPECT: 0
#include <complex>
#include <cstdio>
#include <cmath>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

typedef std::complex<long double> C;
static bool near(long double a, long double b) { return std::fabs(a - b) < 1e-17L * (1 + std::fabs(b)); }

int main() {
  C c(3, 4), d(1, -2);
  CHECK(std::abs(c) == 5 && std::norm(c) == 25 && std::conj(c) == C(3, -4) && std::real(c) == 3 && std::imag(c) == 4);
  CHECK((c * d).real() == 11 && (c * d).imag() == -2 && (c / d).real() == -1 && (c / d).imag() == 2);
  CHECK(c + d == C(4, 2) && c - d == C(2, 6) && -c == C(-3, -4) && c * 2.0L == C(6, 8) && c / 2.0L == C(1.5L, 2));
  C e = c; e *= d; e /= d; e += d; e -= d;
  CHECK(near(e.real(), 3) && near(e.imag(), 4));
  CHECK(near(std::arg(c), 0.927295218001612232428512462922428804L));
  C p = std::polar(2.0L, 0.5L);
  CHECK(near(p.real(), 2 * cosl(0.5L)) && near(p.imag(), 2 * sinl(0.5L)));
  C x = std::exp(C(0, 1));
  CHECK(near(x.real(), cosl(1)) && near(x.imag(), sinl(1)));
  C l = std::log(C(0, 1));
  CHECK(near(l.real(), 0) && near(l.imag(), 1.570796326794896619231321691639751442L));
  C s = std::sqrt(C(-4, 0));
  CHECK(near(s.real(), 0) && near(s.imag(), 2));
  C w = std::pow(C(2, 0), C(3, 0));
  CHECK(near(w.real(), 8) && near(w.imag(), 0));
  C sn = std::sin(C(1, 0)), ch = std::cosh(C(0, 1));
  CHECK(near(sn.real(), sinl(1)) && near(ch.real(), cosl(1)));
  printf("%d\n", fails);
  return fails;
}
