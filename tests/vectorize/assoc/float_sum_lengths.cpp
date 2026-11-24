// The sums for every length from 0 to 70: the vector loop runs two copies of four lanes per iteration, so the lengths
// that are not multiples of eight, and the ones shorter than a copy, run the scalar tail. The values are small
// multiples of 0.25, so every partial sum is exact in float and each length must print the sum computed in order here.
#include <cstdio>
__attribute__((noinline)) static float dot(const float *x, const float *y, int n) {
  float s = 0;
  for (int i = 0; i < n; i++) s += x[i] * y[i];
  return s;
}
static float a[80], b[80];
int main() {
  for (int i = 0; i < 80; i++) {
    a[i] = (float)(i % 13) * 0.25f;
    b[i] = (float)(i % 7) * 0.5f;
  }
  int bad = 0;
  for (int n = 0; n <= 70; n++) {
    float want = 0;
    for (int i = 0; i < n; i++) want += (float)(i % 13) * 0.25f * ((float)(i % 7) * 0.5f);
    float got = dot(a, b, n);
    if (got != want) {
      std::printf("n=%d: got %.4f want %.4f\n", n, got, want);
      bad = 1;
    }
  }
  std::printf("lengths ok: %s\n", bad ? "no" : "yes");
  return bad;
}
