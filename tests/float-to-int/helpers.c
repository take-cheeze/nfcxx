/* The checked float-to-integer helpers (be/nfcxx_ldrt.c) on out-of-range values, printed for tests/float-to-int/run.sh.
   The expected output is gcc's on x86-64 (saturating for __float128, the x87 "integer indefinite" for long double). */
#include <stdio.h>
#include <math.h>
long __nfcxx_f128_to_s(const void *a, int bits);
unsigned long __nfcxx_f128_to_u(const void *a, int bits);
long __nfcxx_ld_to_s(const void *a, int bits);
unsigned long __nfcxx_ld_to_u(const void *a, int bits);
int main(void) {
  __float128 f[] = {1e30Q, -1e30Q, (__float128)NAN, 3e9Q, -0.5Q};
  for (int i = 0; i < 5; i++)
    printf("f128 %d: int=%ld long=%ld uint=%lu ulong=%lu\n", i, __nfcxx_f128_to_s(&f[i], 32), __nfcxx_f128_to_s(&f[i], 64),
           __nfcxx_f128_to_u(&f[i], 32), __nfcxx_f128_to_u(&f[i], 64));
  long double l[] = {1e30L, -1e30L, (long double)NAN};
  for (int i = 0; i < 3; i++) {
    long double x = l[i];
    printf("ld %d: int=%ld long=%ld\n", i, __nfcxx_ld_to_s(&x, 32), __nfcxx_ld_to_s(&x, 64));
  }
  return 0;
}
