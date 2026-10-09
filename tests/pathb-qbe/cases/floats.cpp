// EXPECT: 13
// Floating probes: conversions both ways (truncation toward zero), NaN comparisons, signed zero, float rounding.
__attribute__((noinline)) double d(double x) { return x; }
__attribute__((noinline)) float f(float x) { return x; }
int main() {
  int r = 0;
  double x = d(7.5);
  r += (int)x == 7;
  r += (int)d(-7.5) == -7;
  r += (long)d(1e15) == 1000000000000000L;
  r += (unsigned)d(4000000000.0) == 4000000000u;
  float g = f(0.1f) + 0.2f;
  r += g > 0.29f && g < 0.31f;
  double nan = d(0.0) / d(0.0);
  r += !(nan == nan);
  r += nan != nan;
  r += !(nan < 1.0) && !(nan > 1.0);
  double nz = -d(0.0);
  r += 1.0 / nz < 0;
  r += (float)d(16777217.0) == 16777216.0f;
  r += (double)f(1.5f) * 2 == 3.0;
  unsigned long u = 18000000000000000000ul;
  r += (double)u > 1.7e19;
  r += (unsigned long)d(9.5e18) == 9500000000000000000ul;
  return r;
}
