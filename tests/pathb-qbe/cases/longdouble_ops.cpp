// long double operations (docs/notes/pathb-longdouble.md): arithmetic, comparison, conversion, compound assignment,
// ++/--, ?:, &&/||/!, unary minus, constants (also infinity and NaN), implicit conversions in mixed expressions.
// Every result is printed in hex-float form (%La), so the output equals the gcc backend's only if the x87 results are
// bit for bit the same. EXPECT counts failed checks.
// EXPECT: 0
// STDOUT: same
#include <cstdio>
#include <cstring>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static long double add(long double a, long double b) { return a + b; }
static long double sub(long double a, long double b) { return a - b; }
static long double mul(long double a, long double b) { return a * b; }
static long double dvd(long double a, long double b) { return a / b; }
static bool lt(long double a, long double b) { return a < b; }
static bool le(long double a, long double b) { return a <= b; }
static bool gt(long double a, long double b) { return a > b; }
static bool ge(long double a, long double b) { return a >= b; }
static bool eq(long double a, long double b) { return a == b; }
static bool ne(long double a, long double b) { return a != b; }

template <class T> static long double conv(T v) { return v; }
template <class T> static T back(long double v) { return (T)v; }

static const long double kPi = 3.14159265358979323846264338327950288L;
static long double gl = 0.1L;
static long double ga[4] = {1.0L, 0.1L, 1e4000L, -0.0L};

int main() {
  long double third = 1.0L / 3.0L;
  printf("%La %La %La %La\n", add(third, third), sub(1.0L, third), mul(third, 3.0L), dvd(1.0L, 7.0L));
  printf("%La %La %La\n", kPi, gl, ga[2]);
  CHECK(sizeof(long double) == 16 && alignof(long double) == 16);

  // comparisons
  CHECK(lt(1.0L, 2.0L) && !lt(2.0L, 2.0L) && !lt(3.0L, 2.0L));
  CHECK(le(1.0L, 2.0L) && le(2.0L, 2.0L) && !le(3.0L, 2.0L));
  CHECK(gt(3.0L, 2.0L) && !gt(2.0L, 2.0L) && !gt(1.0L, 2.0L));
  CHECK(ge(3.0L, 2.0L) && ge(2.0L, 2.0L) && !ge(1.0L, 2.0L));
  CHECK(eq(0.5L, 0.5L) && !eq(0.5L, 0.25L) && ne(0.5L, 0.25L) && !ne(0.5L, 0.5L));
  CHECK(eq(0.0L, -0.0L));
  long double inf = ga[2] * ga[2];
  long double nan = inf - inf;
  CHECK(!(nan == nan) && nan != nan && !(nan < 1) && !(nan > 1) && !(nan <= 1) && !(nan >= 1));
  CHECK(!lt(nan, 1) && ne(nan, nan) && !eq(nan, nan));
  CHECK(ga[2] > 1e308L && ga[2] > 1.7976931348623157e308L);   // beyond double's range, inside long double's
  CHECK(1e4000L * 1e-4000L == 1.0L);

  // conversions from integers and floating types
  CHECK(conv<int>(-5) == -5.0L && conv<unsigned>(4000000000u) == 4000000000.0L);
  CHECK(conv<long>(-9223372036854775807L - 1) == -9223372036854775808.0L);
  CHECK(conv<unsigned long>(18446744073709551615UL) == 18446744073709551616.0L - 1.0L);
  CHECK(conv<short>(-3) == -3.0L && conv<unsigned char>(200) == 200.0L && conv<signed char>(-100) == -100.0L);
  CHECK(conv<bool>(true) == 1.0L && conv<char>('A') == 65.0L);
  CHECK(conv<float>(0.1f) == (long double)0.1f && conv<float>(0.1f) != 0.1L);
  CHECK(conv<double>(0.1) == (long double)0.1 && conv<double>(0.1) != 0.1L);

  // conversions to integers truncate toward zero; to float and double round
  CHECK(back<int>(2.99L) == 2 && back<int>(-2.99L) == -2 && back<int>(0.99L) == 0 && back<int>(-0.99L) == 0);
  CHECK(back<long>(9223372036854775807.0L) == 9223372036854775807L);
  CHECK(back<long>(-9223372036854775808.0L) == (-9223372036854775807L - 1));
  CHECK(back<unsigned long>(18446744073709551615.0L) == 18446744073709551615UL);
  CHECK(back<unsigned char>(255.9L) == 255 && back<signed char>(-128.9L) == -128 && back<short>(32767.5L) == 32767);
  CHECK(back<unsigned>(4294967295.5L) == 4294967295u && back<char>(65.5L) == 'A');
  CHECK(back<bool>(0.25L) == true && back<bool>(0.0L) == false && back<bool>(-0.0L) == false && back<bool>(nan) == true);
  CHECK(back<double>(0.1L) == 0.1 && back<float>(0.1L) == 0.1f);
  CHECK(back<double>(1e4000L) > 1e308 && back<double>(1e-4000L) == 0.0);
  printf("%.17g %.9g %d %lu\n", back<double>(kPi), back<float>(kPi), back<int>(-7.5L), back<unsigned long>(1e19L));

  // compound assignment, ++ and --, mixed with other types
  long double x = 5;
  x += 2; x -= 1; x *= 4; x /= 3;
  CHECK(x == 8.0L);
  x += 1; x++; ++x; x--; --x;
  CHECK(x == 9.0L);
  long double y = x++;
  long double z = ++x;
  CHECK(y == 9.0L && z == 11.0L && x == 11.0L);
  y = x--; z = --x;
  CHECK(y == 11.0L && z == 9.0L && x == 9.0L);
  int i = 7; i += 2.5L;          // computed in long double, converted back: 9
  CHECK(i == 9);
  i = 10; i *= 0.35L;            // 3.5 -> 3
  CHECK(i == 3);
  double d = 1.5; d += 0.25L; d *= 2.0L;
  CHECK(d == 3.5);
  float f = 1.0f; f /= 3.0L;
  CHECK(f == (float)(1.0L / 3.0L));
  long double w = 1; w = w + 2 * 3 - 4 / 2.0 + 1.0f;   // mixed int, double, float
  CHECK(w == 6.0L);
  long double u = 3; u = -u; CHECK(u == -3.0L); u = +u; CHECK(u == -3.0L); u = -(-u); CHECK(u == -3.0L);
  CHECK(-0.0L == 0.0L && 1.0L / -0.0L < 0 && 1.0L / 0.0L > 0);

  // ?: && || !
  long double p = (x > 5) ? 1.5L : 2.5L;
  long double q = (x < 5) ? p : -p;
  CHECK(p == 1.5L && q == -1.5L);
  CHECK((0.0L ? 1 : 2) == 2 && (0.5L ? 1 : 2) == 1 && (nan ? 1 : 2) == 1);
  CHECK(!(0.0L) && !(-0.0L) && !!(0.5L) && !nan == false);
  CHECK((0.5L && 2) && !(0.0L && 1) && (0.0L || 3) && !(0.0L || 0));
  int count = 0;
  for (long double t = 0; t < 1.0L; t += 0.125L) count++;
  CHECK(count == 8);
  long double s = 0; int n = 0;
  while (s < 100.0L) { s = s * 2 + 1; n++; }
  CHECK(n == 7 && s == 127.0L);

  // raw representation
  long double one = 1.0L;
  unsigned char b[16]; memcpy(b, &one, 16);
  CHECK(b[7] == 0x80 && b[8] == 0xff && b[9] == 0x3f && b[0] == 0);
  memcpy(b, &inf, 16);
  CHECK(b[7] == 0x80 && b[8] == 0xff && b[9] == 0x7f);
  printf("%La %La %La\n", inf, -inf, ga[3]);
  printf("%d\n", fails);
  return fails;
}
