// EXPECT: 16
// double and float arithmetic, conversions between them and to integers, comparisons.
int main() {
  double x = 2.5;
  float f = 1.25f;
  double y = x * 4.0 - 1.0;   // 9
  float g = f * 3.0f;         // 3.75
  int i = (int)y;             // 9
  int j = (int)(double)g;     // 3
  unsigned long ul = 12345678901234ul;
  double dl = (double)ul;
  int big = dl > 1.0e12 ? 1 : 0;
  int neg = -x < 0.0 ? 1 : 0;
  return (i + j + big + neg + (int)(y / x) + (int)(-f)) & 0xff;
}
