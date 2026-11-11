// LP64-ONLY: the variadic lowering is for LP64 (the emscripten and asan modes refuse it)
// EXPECT: 234
// A variadic function the module defines: its arguments are read with va_start and va_arg, the callee gets
// int, long, double and pointer arguments, and a variadic function calls another with its va_list.
// The g++ result is 234: the sum of the five results in main (forward(0, 4, 2) reads 4 from the copy and 4 from ap).
#include <stdarg.h>

static int sum_ints(int n, ...) {
  va_list ap;
  va_start(ap, n);
  int s = 0;
  for (int i = 0; i < n; i++) s += va_arg(ap, int);
  va_end(ap);
  return s;
}

static double mix(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double d = 0;
  for (int i = 0; i < n; i++) d += va_arg(ap, double);
  long l = va_arg(ap, long);
  int *p = va_arg(ap, int *);
  va_end(ap);
  return d + (double)l + (double)*p;
}

static int first(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int v = va_arg(ap, int);
  va_end(ap);
  return v + fmt[0];
}

static int forward(int n, ...) {
  va_list ap, copy;
  va_start(ap, n);
  va_copy(copy, ap);
  int a = va_arg(copy, int);
  va_end(copy);
  int b = va_arg(ap, int);
  va_end(ap);
  return a * 10 + b;
}

int main() {
  int seven = 7;
  int r = sum_ints(4, 1, 2, 3, 4);            // 10
  r += sum_ints(0);                           // 0
  r += (int)mix(2, 1.5, 2.25, 100L, &seven);  // 1.5 + 2.25 + 100 + 7 = 110.75 -> 110
  r += first("A", 5);                         // 5 + 65 = 70
  r += forward(0, 4, 2);                      // 4 * 10 + 2 = 42
  return r;                                   // 10 + 0 + 110 + 70 + 44
}
