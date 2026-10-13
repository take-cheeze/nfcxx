// EXPECT: 16
// EXPECT-ILP32: 15
// double and float arithmetic, conversions between them and to integers, comparisons. The unsigned long is 32 bits
// under ILP32 (--emscripten), so 12345678901234 does not fit and the value is 1942892530: big is 0 there. The
// EXPECT-ILP32 value is g++ -m32 (freestanding, -O0), the EXPECT value is g++ at -O0 on x86-64.
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
