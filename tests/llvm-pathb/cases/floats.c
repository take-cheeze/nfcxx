// EXPECT: 16
// double and float arithmetic, comparisons with NaN, and conversions between integers and floating types.
int main(void) {
  double a = 1.5, b = 0.25;
  double c = a * b + 2.0;                /* 2.375 */
  float f = (float)c;                    /* 2.375 */
  int i = (int)(c * 4.0);                /* 9 */
  double z = 0.0;
  double nan = z / z;
  int ne = nan != nan;                   /* 1: C's != is true on NaN */
  int lt = nan < 1.0;                    /* 0 */
  int eq = a == 1.5;                     /* 1 */
  double d = (double)i / 2;              /* 4.5 */
  long big = (long)(d * 10.0);           /* 45 */
  int neg = (int)(-a * -2.0);            /* 3 */
  return i + ne + lt + eq + (int)f + neg + (int)big - 45;   /* 9 + 1 + 0 + 1 + 2 + 3 + 0 = 16 */
}
