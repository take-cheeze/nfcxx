// Path B: variadic function definitions. va_start / va_arg / va_end / va_copy in the callee: integers, pointers and
// doubles mixed, more arguments than fit in registers (the overflow area), a va_list passed on to vsnprintf,
// and a va_list parameter that decays to a pointer.
// EXPECT: 30
// STDOUT: same
#include <cstdarg>
#include <cstdio>

static long sum_ints(int n, ...)
{
  va_list ap;
  va_start(ap, n);
  long s = 0;
  for (int i = 0; i < n; i++) s += va_arg(ap, int);
  va_end(ap);
  return s;
}

static double mixed(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  double t = 0;
  for (const char *p = fmt; *p; p++) {
    if (*p == 'i') t += va_arg(ap, int);
    else if (*p == 'l') t += (double)va_arg(ap, long);
    else if (*p == 'd') t += va_arg(ap, double);
    else if (*p == 's') t += (double)(va_arg(ap, const char *))[0];
  }
  va_end(ap);
  return t;
}

static int format_into(char *buf, unsigned long n, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int r = std::vsnprintf(buf, n, fmt, ap);
  va_end(ap);
  return r;
}

static int take_list(va_list ap)   // a va_list parameter is a pointer
{
  int a = va_arg(ap, int);
  int b = va_arg(ap, int);
  return a * 10 + b;
}

static int twice(int n, ...)
{
  va_list ap, ap2;
  va_start(ap, n);
  va_copy(ap2, ap);
  int x = take_list(ap);   // consumes the first two of ap
  int y = take_list(ap2);  // the copy starts at the first again
  va_end(ap2);
  va_end(ap);
  return (x == y) ? x : -1;
}

int main()
{
  int ok = 0;
  if (sum_ints(12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) == 78) ok += 4;       // past the register arguments
  if (mixed("idls", 3, 2.5, 100L, "A") == 3 + 2.5 + 100 + 65) ok += 4;
  if (mixed("dddddddddd", 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0) == 55.0) ok += 4;   // past the xmm registers
  char buf[64];
  int r = format_into(buf, sizeof buf, "%d-%s-%.1f", 42, "xy", 1.5);
  std::printf("%d [%s]\n", r, buf);
  if (r == 9 && buf[0] == '4' && buf[3] == 'x') ok += 4;
  if (twice(2, 3, 4) == 34) ok += 4;
  return ok + 10;
}
