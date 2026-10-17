// EXPECT-REFUSED: variadic definitions (va_start)
// A C-style variadic definition reads its arguments with va_start, which the spike does not support.
#include <stdarg.h>
static int sum(int n, ...) { va_list ap; va_start(ap, n); int s = 0; for (int i = 0; i < n; i++) s += va_arg(ap, int); va_end(ap); return s; }
int main(void) { return sum(3, 1, 2, 3); }
