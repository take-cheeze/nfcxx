int printf(const char *, ...);
long double g_twice(long double);
long double g_const(void);
long double g_sum(int, ...);
long double g_mix(int, ...);
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
  printf("%Lf %Lf\n", g_mix(1, 1, 2.5, a), g_mix(4, 1, 2.0, a, 3, 4.0, b, 5, 6.0, c, 7, 8.0, a));
  g_sum(1, a);
  return 0;
}
