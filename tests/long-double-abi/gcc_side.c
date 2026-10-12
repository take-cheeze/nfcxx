#include <stdarg.h>
long double g_twice(long double x) { return x * 2 + 1; }
long double g_const(void) { return 3.25L; }
long double g_sum(int n, ...) { va_list ap; long double s = 0; va_start(ap, n); for (int i = 0; i < n; i++) s += va_arg(ap, long double); va_end(ap); return s; }
long double g_pick(int k, long double a, long double b, long double c) { return k ? a : k == 2 ? b : c; }
