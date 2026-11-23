// A float sum: the vectorizer keeps four partial sums only with -fassociative-math (the sum is then reassociated).
// The values are multiples of 0.25 below 2^20, so every partial sum is exact in float, and both builds print the same.
#include <cstdio>
__attribute__((noinline)) static float dot(const float *x, const float *y, int n) {
  float s = 0;
  for (int i = 0; i < n; i++) s += x[i] * y[i];
  return s;
}
static float a[1000], b[1000];
int main() {
  for (int i = 0; i < 1000; i++) {
    a[i] = (float)(i % 13) * 0.25f;
    b[i] = (float)(i % 7) * 0.5f;
  }
  float s = dot(a, b, 1000);
  std::printf("dot %.4f\n", s);
  return s == 0 ? 1 : 0;
}
