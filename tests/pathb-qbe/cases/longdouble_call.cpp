// long double in calls (docs/notes/pathb-longdouble.md, "Calling convention"): a long double argument is 16 bytes in
// memory (class X87), a result comes back in st(0). Path B defines such a function as __nfcxx_ldr_F with a result
// pointer and reaches libm and other units through thunks. Covered: many parameters (stack arguments, the extra pointer
// after six integer registers), function pointers, virtual functions, recursion, variadic functions taking and
// returning long double, callbacks, templates and std::function.
// EXPECT: 0
// STDOUT: same
#include <cstdio>
#include <cstdarg>
#include <cmath>
#include <cstdlib>
#include <functional>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

long double id(long double x) { return x; }
long double add3(long double a, long double b, long double c) { return a + b + c; }
long double mixed(int a, double b, long double c, float d, long double e, long l) { return a + b + c + d + e + l; }
long double ints6(int a, int b, int c, int d, int e, int f, long double x) { return a + b + c + d + e + f + x; }
long double ints5(int a, int b, int c, int d, int e, long double x) { return a + b + c + d + e + x; }
long double ints7(int a, int b, int c, int d, int e, int f, int g, long double x, int h) { return a + b + c + d + e + f + g + x + h; }
long double many_ld(long double a, long double b, long double c, long double d, long double e, long double f,
                    long double g, long double h, long double i, long double j) {
  return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10;
}
long double sink_double(double a, double b, double c, double d, double e, double f, double g, double h, double i, long double x) {
  return a + b + c + d + e + f + g + h + i + x;
}
double ld_to_double(long double x, double y) { return (double)x * y; }
long double from_ptr(const long double* p, long n) { long double s = 0; for (long i = 0; i < n; i++) s += p[i]; return s; }
void by_ref(long double& r, long double v) { r = v * 2; }
long double fact(int n) { return n <= 1 ? 1.0L : n * fact(n - 1); }
long double fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static long double hidden(long double x) { return x * 10; }

long double sum_va(int n, ...) {
  va_list ap; va_start(ap, n);
  long double s = 0;
  for (int i = 0; i < n; i++) s += va_arg(ap, long double);
  va_end(ap);
  return s;
}
double mixed_va(int n, ...) {
  va_list ap; va_start(ap, n);
  double s = 0;
  for (int i = 0; i < n; i++) { s += va_arg(ap, int); s += (double)va_arg(ap, long double); s += va_arg(ap, double); }
  va_end(ap);
  return s;
}
long double pass_va(const char* tag, long double first, ...) {
  va_list ap; va_start(ap, first);
  long double s = first + va_arg(ap, long double);
  va_end(ap);
  return s + tag[0];
}

struct V { virtual long double f(long double x, int k) { return x + k; } virtual ~V() {} };
struct W : V { long double f(long double x, int k) override { return x * k; } };
struct S { long double scale; long double apply(long double x) const { return x * scale; } static long double twice(long double x) { return 2 * x; } };

template <class T> T twice(T x) { return x + x; }
template <class T, class... A> T sum_all(T first, A... rest) { if constexpr (sizeof...(rest) == 0) return first; else return first + sum_all<T>(rest...); }

long double (*fp)(long double) = hidden;
long double (*fp2)(long double) = sqrtl;
long double (*table[3])(long double) = {id, hidden, fabsl};

int cmp_ld(const void* a, const void* b) {
  long double x = *(const long double*)a, y = *(const long double*)b;
  return x < y ? -1 : x > y ? 1 : 0;
}

int main() {
  CHECK(id(1.5L) == 1.5L && add3(1, 2.5L, 3.25L) == 6.75L);
  CHECK(mixed(1, 2.5, 3.25L, 0.5f, 100.0L, 1000) == 1107.25L);
  CHECK(ints6(1, 2, 3, 4, 5, 6, 0.5L) == 21.5L && ints5(1, 2, 3, 4, 5, 0.5L) == 15.5L);
  CHECK(ints7(1, 2, 3, 4, 5, 6, 7, 0.5L, 8) == 36.5L);
  CHECK(many_ld(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) == 385.0L);
  CHECK(sink_double(1, 2, 3, 4, 5, 6, 7, 8, 9, 0.5L) == 45.5L);
  CHECK(ld_to_double(2.5L, 4.0) == 10.0);
  long double arr[3] = {1.25L, 2.25L, 3.25L};
  CHECK(from_ptr(arr, 3) == 6.75L);
  long double r = 0; by_ref(r, 4.25L);
  CHECK(r == 8.5L);
  CHECK(fact(20) == 2432902008176640000.0L && fact(25) > 1.5e25L && fib(20) == 6765.0L);

  CHECK(fp(2) == 20 && fp2(81) == 9 && table[0](3) == 3 && table[1](3) == 30 && table[2](-4.5L) == 4.5L);
  long double (*local)(long double, long double, long double) = add3;
  CHECK(local(1, 2, 3) == 6);

  CHECK(sum_va(3, 1.5L, 2.25L, 3.125L) == 6.875L && sum_va(0) == 0);
  CHECK(mixed_va(2, 1, 2.5L, 0.25, 3, 4.5L, 0.5) == 11.75);
  CHECK(pass_va("A", 1.5L, 2.5L) == 4.0L + 65);

  W w; V* v = &w; V v0;
  CHECK(v->f(4.0L, 3) == 12 && v0.f(4.0L, 3) == 7 && static_cast<V&>(w).f(1, 2) == 2);
  S s{2.5L};
  CHECK(s.apply(4) == 10 && S::twice(1.25L) == 2.5L);
  auto mp = &S::apply;
  CHECK((s.*mp)(2) == 5);
  CHECK(twice(2.25L) == 4.5L && twice<long double>(1) == 2 && sum_all(1.5L, 2.5L, 3.0L, 4.0L) == 11.0L);

  std::function<long double(long double)> f1 = [](long double x) { return x * x; };
  std::function<long double(long double, long double)> f2 = [](long double a, long double b) { return a - b; };
  long double (*pf)(long double) = sqrtl;
  std::function<long double(long double)> f3 = pf;
  std::function<long double()> f4 = [] { return 0.125L; };
  CHECK(f1(1.5L) == 2.25L && f2(1, 3) == -2 && f3(2.25L) == 1.5L && f4() == 0.125L);

  // callbacks from C code
  long double data[6] = {5, 3, 9, 1, 7, 2};
  qsort(data, 6, sizeof data[0], cmp_ld);
  CHECK(data[0] == 1 && data[5] == 9 && data[2] == 3);

  // libm through the call thunks
  CHECK(sqrtl(2.25L) == 1.5L && fabsl(-1.5L) == 1.5L && floorl(-1.5L) == -2 && ceill(-1.5L) == -1 && truncl(2.9L) == 2);
  CHECK(powl(2, 10) == 1024 && fmodl(7.5L, 2) == 1.5L && copysignl(3, -1) == -3 && fmaxl(1, 2) == 2 && hypotl(3, 4) == 5);
  CHECK(ldexpl(1.5L, 3) == 12 && scalbnl(1, 4) == 16 && roundl(2.5L) == 3 && nearbyintl(2.5L) == 2 && lroundl(-2.5L) == -3);
  int e = 0; long double m = frexpl(48.0L, &e);
  CHECK(m == 0.75L && e == 6);
  long double ip; long double fr = modfl(3.75L, &ip);
  CHECK(fr == 0.75L && ip == 3);
  CHECK(strtold("2.5e3", nullptr) == 2500.0L && strtold("0x1.8p1", nullptr) == 3.0L && atof("1.5") == 1.5);
  char* endp; long double pv = strtold("3.5xyz", &endp);
  CHECK(pv == 3.5L && endp[0] == 'x');
  printf("%La %La %La %La\n", sinl(1.0L), expl(1.0L), logl(10.0L), atan2l(1.0L, 3.0L));
  printf("%d\n", fails);
  return fails;
}
