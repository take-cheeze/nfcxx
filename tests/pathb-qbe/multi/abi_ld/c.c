/* The C side of multi/abi_ld: built by the host C compiler. */
#include <complex.h>
#include <math.h>

long double c_id(long double x) { return x; }
long double c_mix(int a, double b, long double c, float d, long double e, long l) { return a + b + c + d + e + l; }
long double c_ints7(int a, int b, int c, int d, int e, int f, int g, long double x, int h) { return a + b + c + d + e + f + g + x + h; }
long double c_ints6(int a, int b, int c, int d, int e, int f, long double x) { return a + b + c + d + e + f + x; }
long double c_none(void) { return 0.1L; }
long double c_sum_arr(const long double* p, int n) { long double s = 0; for (int i = 0; i < n; i++) s += p[i]; return s; }
_Complex long double c_cmul(_Complex long double a, _Complex long double b) { return a * b; }
long double c_cabs(_Complex long double z) { return cabsl(z); }

long double cpp_scale(long double x, int k);
long double cpp_mix(int a, double b, long double c, float d, long double e, long l);
long double cpp_ints7(int a, int b, int c, int d, int e, int f, int g, long double x, int h);
long double cpp_ints6(int a, int b, int c, int d, int e, int f, long double x);
long double cpp_none(void);
_Complex long double cpp_cswap(_Complex long double z);

int c_test_cpp(void)
{
  int fails = 0;
  _Complex long double z = 1.5L + 2.5L * I, w;
  if (cpp_scale(2.5L, 4) != 10.0L) fails++;
  if (cpp_mix(1, 2.5, 3.25L, 0.5f, 100.0L, 1000) != 1107.25L) fails++;
  if (cpp_ints7(1, 2, 3, 4, 5, 6, 7, 0.5L, 8) != 36.5L) fails++;
  if (cpp_ints6(1, 2, 3, 4, 5, 6, 0.5L) != 21.5L) fails++;
  if (cpp_none() != 0.1L) fails++;
  w = cpp_cswap(z);
  if (creall(w) != 1.5L || cimagl(w) != -2.5L) fails++;
  return fails;
}
