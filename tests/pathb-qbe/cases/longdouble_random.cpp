// <random> with long double (docs/notes/pathb-longdouble.md): std::uniform_real_distribution, normal_distribution,
// generate_canonical and the other real-valued distributions instantiated for long double. The engines are the same
// code as for double, so the sequences must equal the gcc backend's bit for bit.
// EXPECT: 0
// STDOUT: same
#include <random>
#include <cstdio>
#include <cmath>
#include <vector>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main() {
  std::mt19937 gen(42);
  std::uniform_real_distribution<long double> ud(0.0L, 1.0L);
  long double lo = 2, hi = -1, sum = 0;
  for (int i = 0; i < 1000; i++) {
    long double v = ud(gen);
    if (v < lo) lo = v;
    if (v > hi) hi = v;
    sum += v;
  }
  CHECK(lo >= 0 && hi < 1 && sum > 400 && sum < 600);
  printf("%La %La %La\n", lo, hi, sum);

  std::normal_distribution<long double> nd(10.0L, 2.0L);
  long double s = 0, s2 = 0;
  for (int i = 0; i < 1000; i++) { long double v = nd(gen); s += v; s2 += v * v; }
  long double mean = s / 1000, var = s2 / 1000 - mean * mean;
  CHECK(mean > 9.5L && mean < 10.5L && var > 3 && var < 5);
  printf("%La %La\n", mean, var);

  std::mt19937_64 g64(7);
  for (int bits : {24, 53, 64}) {
    long double c = bits == 24 ? std::generate_canonical<long double, 24>(g64)
                  : bits == 53 ? std::generate_canonical<long double, 53>(g64)
                               : std::generate_canonical<long double, 64>(g64);
    CHECK(c >= 0 && c < 1);
    printf("%d %La\n", bits, c);
  }
  std::exponential_distribution<long double> ed(2.0L);
  std::gamma_distribution<long double> gd(2.0L, 1.5L);
  std::cauchy_distribution<long double> cd(0.0L, 1.0L);
  std::lognormal_distribution<long double> ld(0.0L, 0.5L);
  std::weibull_distribution<long double> wd(2.0L, 1.0L);
  std::chi_squared_distribution<long double> xd(3.0L);
  std::student_t_distribution<long double> td(5.0L);
  std::extreme_value_distribution<long double> evd(0.0L, 1.0L);
  std::fisher_f_distribution<long double> fd(3.0L, 4.0L);
  std::uniform_real_distribution<long double> wide(-1e300L, 1e300L);
  long double r1 = ed(gen), r2 = gd(gen), r3 = cd(gen), r4 = ld(gen);   // one statement each: the order of evaluation of
  printf("%La %La %La %La\n", r1, r2, r3, r4);                          // call arguments is not specified
  long double r5 = wd(gen), r6 = xd(gen), r7 = td(gen), r8 = evd(gen), r9 = fd(gen);
  printf("%La %La %La %La %La\n", r5, r6, r7, r8, r9);
  printf("%La\n", wide(gen));
  const long double bounds[] = {0.0L, 1.0L, 3.0L}, weights[] = {1.0L, 2.0L};
  std::piecewise_constant_distribution<long double> pcd(bounds, bounds + 3, weights);
  std::discrete_distribution<int> dd({1.5L, 2.5L, 3.5L});
  long double rp = pcd(gen); int rd = dd(gen);
  printf("%La %d\n", rp, rd);
  printf("%d\n", fails);
  return fails;
}
