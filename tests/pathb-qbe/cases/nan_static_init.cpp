// EXPECT: 0
// STDOUT: same
// A NaN in a static initializer (a global of type float, double and an array of float): the initializer is the
// positive quiet NaN in every backend. Path B's interpreter table used to read the NaN text with Float() and fail on it,
// which stopped the translation unit (the P0226R1 STL test, tests/std).
#include <cmath>
#include <cstdio>
#include <limits>
static float nf = std::numeric_limits<float>::quiet_NaN();
static double nd = NAN;
static const float tab[2] = {NAN, 1.5f};
int main() {
  std::printf("%d %d %d %d\n", std::isnan(nf), std::isnan(nd), std::isnan(tab[0]), (int)tab[1]);
  return 0;
}
