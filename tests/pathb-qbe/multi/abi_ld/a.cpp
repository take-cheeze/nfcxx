// Path B and the host C compiler exchange long double values: arguments in memory, results in st(0), and
// _Complex long double (st(0) and st(1)); with parameters beyond the six integer registers. c.c is built by cc,
// a.cpp by the Path B pipeline (docs/notes/pathb-longdouble.md, "Calling convention": the call thunk
// __nfcxx_x87c_F reaches C's F, the entry thunk F is what C calls).
// EXPECT: 0
// GCC: undefined   (the gcc backend cannot run the _Complex long double calls; the C compiler's own ABI is the reference here)
#include <cstdio>
#include <complex>

extern "C" {
long double c_id(long double x);
long double c_mix(int a, double b, long double c, float d, long double e, long l);
long double c_ints7(int a, int b, int c, int d, int e, int f, int g, long double x, int h);
long double c_ints6(int a, int b, int c, int d, int e, int f, long double x);
long double c_none(void);
long double c_sum_arr(const long double* p, int n);
_Complex long double c_cmul(_Complex long double a, _Complex long double b);
long double c_cabs(_Complex long double z);
int c_test_cpp(void);   // calls the functions below from C and returns the number of failures

// defined here, called from C
long double cpp_scale(long double x, int k) { return x * k; }
long double cpp_mix(int a, double b, long double c, float d, long double e, long l) { return a + b + c + d + e + l; }
long double cpp_ints7(int a, int b, int c, int d, int e, int f, int g, long double x, int h) { return a + b + c + d + e + f + g + x + h; }
long double cpp_ints6(int a, int b, int c, int d, int e, int f, long double x) { return a + b + c + d + e + f + x; }
long double cpp_none(void) { return 0.1L; }
_Complex long double cpp_cswap(_Complex long double z) { _Complex long double r; __real__ r = __real__ z; __imag__ r = -(__imag__ z); return r; }
}

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main() {
  CHECK(c_id(2.5L) == 2.5L && c_id(-1e4000L) == -1e4000L);
  CHECK(c_mix(1, 2.5, 3.25L, 0.5f, 100.0L, 1000) == 1107.25L);
  CHECK(c_ints7(1, 2, 3, 4, 5, 6, 7, 0.5L, 8) == 36.5L);
  CHECK(c_ints6(1, 2, 3, 4, 5, 6, 0.5L) == 21.5L);
  CHECK(c_none() == 0.1L);
  long double arr[3] = {1.5L, 2.5L, 3.5L};
  CHECK(c_sum_arr(arr, 3) == 7.5L);
  _Complex long double a, b;
  __real__ a = 3.0L; __imag__ a = 4.0L; __real__ b = 1.0L; __imag__ b = -2.0L;
  _Complex long double p = c_cmul(a, b);
  CHECK(__real__ p == 11.0L && __imag__ p == -2.0L);
  CHECK(c_cabs(a) == 5.0L);
  std::complex<long double> sc(1.5L, -0.5L);
  CHECK((sc * sc).real() == 2.0L && (sc * sc).imag() == -1.5L);
  fails += c_test_cpp();
  printf("%d\n", fails);
  return fails;
}
