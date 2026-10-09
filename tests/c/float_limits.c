/* EXPECT: 0 */
/* <float.h>'s DBL_MIN / DBL_MAX / DBL_EPSILON / FLT_* are cast long double literals; cproc used to emit an
   invalid QBE truncd for them. */
#include <float.h>
#include <string.h>
int main(void) {
  double mn = DBL_MIN, mx = DBL_MAX, ep = DBL_EPSILON;
  float fm = FLT_MAX, fe = FLT_EPSILON;
  unsigned long b; memcpy(&b, &mn, 8); if (b != 0x0010000000000000UL) return 1;
  memcpy(&b, &mx, 8); if (b != 0x7fefffffffffffffUL) return 2;
  memcpy(&b, &ep, 8); if (b != 0x3cb0000000000000UL) return 3;
  unsigned int f; memcpy(&f, &fm, 4); if (f != 0x7f7fffffU) return 4;
  memcpy(&f, &fe, 4); if (f != 0x34000000U) return 5;
  return 0;
}
