// Static initializers folded by EDG from out-of-range float-to-integer conversions. The values are gcc's (checked on
// x86-64, C and C++); the expected output is in run.sh. Folding must not depend on the host the front end runs on.
#include <cstdio>
#include <cmath>
static signed char a = (signed char)(double)(3e9);
static unsigned char b = (unsigned char)(double)(3e9);
static unsigned short c = (unsigned short)(double)(3e9);
static short d = (short)(double)(3e9);
static unsigned char e = (unsigned char)(double)(-5.0);
static unsigned char f = (unsigned char)(double)(300.0);
static unsigned short g = (unsigned short)(double)(1e30);
static unsigned int h = (unsigned int)(double)(1e30);
static unsigned a1 = (unsigned)(double)NAN;
static unsigned long a2 = (unsigned long)(double)INFINITY;
static unsigned char a3 = (unsigned char)(double)-INFINITY;
static unsigned a4 = (unsigned)(float)INFINITY;
static unsigned long a5 = (unsigned long)(long double)1e30L;
static unsigned short a6 = (unsigned short)(double)-1e30;
static unsigned long long a7 = (unsigned long long)(double)1e30;
static int a8 = (int)(double)NAN;
int main() {
  std::printf("%d %u %u %d %u %u %d %u\n", a, b, c, d, e, f, g, h);
  std::printf("%u %lu %u %u %lu %u %llu %d\n", a1, a2, a3, a4, a5, a6, a7, a8);
  return 0;
}
