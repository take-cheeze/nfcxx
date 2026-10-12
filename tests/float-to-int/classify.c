#include <stdio.h>
#define P(name, x) printf("%s %d\n", name, (int)(x))
#define ALL(v, suf) do { \
  double d = (v); float f = (float)(v); long double l = (long double)(v); __float128 q = (__float128)(v); \
  P("nan" #suf, __builtin_isnan(v)); P("isfin" #suf, __builtin_isfinite(v)); P("isinf" #suf, __builtin_isinf(v)); \
  P("isnorm" #suf, __builtin_isnormal(v)); P("sign" #suf, !!__builtin_signbit(v)); \
  P("fpc" #suf, __builtin_fpclassify(1, 2, 3, 4, 5, v)); \
  P("nan_d" #suf, __builtin_isnan(d)); P("inf_f" #suf, __builtin_isinf(f)); P("norm_l" #suf, __builtin_isnormal(l)); \
  P("fin_q" #suf, __builtin_isfinite(q)); P("sign_q" #suf, !!__builtin_signbit(q)); P("sign_l" #suf, !!__builtin_signbit(l)); \
  P("sign_f" #suf, !!__builtin_signbit(f)); P("fpc_q" #suf, __builtin_fpclassify(1, 2, 3, 4, 5, q)); \
  P("fpc_l" #suf, __builtin_fpclassify(1, 2, 3, 4, 5, l)); \
} while (0)
int main(void) {
  volatile double z = 0.0, nz = -0.0, pinf = 1.0/0.0, ninf = -1.0/0.0, nan_ = 0.0/0.0, nnan = -(0.0/0.0), sub = 1e-310, mn = 2.2250738585072014e-308, neg = -3.5;
  ALL(z, z); ALL(nz, nz); ALL(pinf, pinf); ALL(ninf, ninf); ALL(nan_, nan); ALL(nnan, nnan); ALL(sub, sub); ALL(mn, mn); ALL(neg, neg);
  printf("gt %d lt %d un %d lg %d\n", __builtin_isgreater(pinf, neg), __builtin_isless(sub, mn), __builtin_isunordered(nan_, z), __builtin_islessgreater(z, neg));
  printf("ge %d le %d\n", __builtin_isgreaterequal(neg, neg), __builtin_islessequal(nan_, z));
  return 0;
}
