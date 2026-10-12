int printf(const char *, ...);
long double g_twice(long double);
long double g_const(void);
long double g_sum(int, ...);
long double g_pick(int, long double, long double, long double);
long double o_twice(long double x) { return x * 2 + 1; }
long double o_mix(int n, long double a, int b, long double c) { return a - c + b + n; }
volatile long double va = 1.5L, vb = -4.0L, vc = 1e-300L;
int main(void) {
  long double a = va, b = vb, c = vc;
  printf("%Lf\n", g_twice(a));
  printf("%Lf\n", g_const());
  printf("%Lf\n", g_sum(3, a, b, c));
  printf("%Lf %Lf\n", g_pick(2, a, b, c), g_pick(3, a, b, c));
  printf("%Lf\n", o_twice(b));
  printf("%Lf\n", o_mix(2, a, 7, b));
  g_sum(1, a);
  return 0;
}
