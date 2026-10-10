// EXPECT: 0
// STDOUT: same
// va_arg of structs by value (System V x86-64): structs of up to 16 bytes travel in registers by eightbyte class
// (INTEGER or SSE), a struct that no longer fits the remaining registers and every struct over 16 bytes go to the
// overflow area. The callers are compiled by the same compiler, and one call crosses a C library routine (vsnprintf).
#include <cstdarg>
#include <cstdio>
#include <cstring>

struct I1 { int a; };
struct I2 { long a, b; };
struct C3 { char c[3]; };
struct F2 { float x, y; };
struct D1 { double d; };
struct D2 { double a, b; };
struct M1 { int i; double d; };       // INTEGER, SSE
struct M2 { double d; long l; };      // SSE, INTEGER
struct M3 { float f; int i; };        // one eightbyte, INTEGER
struct M4 { float f; int i; double d; };  // INTEGER, SSE
struct B24 { long a, b, c; };         // memory
struct B20 { int a[5]; };             // memory
struct Pad { char c; short s; int i; long l; };
struct U1 { union { long l; double d; } u; long k; };
struct E {};

static long fold(struct I1 v) { return v.a; }

static long ints(int n, ...) {
  va_list ap;
  va_start(ap, n);
  long s = 0;
  for (int k = 0; k < n; k++) {
    I1 a = va_arg(ap, I1);
    I2 b = va_arg(ap, I2);
    C3 c = va_arg(ap, C3);
    s = s * 7 + a.a + b.a * 3 + b.b * 5 + c.c[0] + c.c[1] * 2 + c.c[2] * 3;
  }
  va_end(ap);
  return s;
}

static double floats(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double s = 0;
  for (int k = 0; k < n; k++) {
    F2 f = va_arg(ap, F2);
    D1 d = va_arg(ap, D1);
    D2 e = va_arg(ap, D2);
    s = s * 1.5 + f.x + 2 * f.y + 3 * d.d + 4 * e.a + 5 * e.b;
  }
  va_end(ap);
  return s;
}

static double mixed(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double s = 0;
  for (int k = 0; k < n; k++) {
    M1 a = va_arg(ap, M1);
    M2 b = va_arg(ap, M2);
    M3 c = va_arg(ap, M3);
    M4 d = va_arg(ap, M4);
    s = s * 1.25 + a.i + a.d + b.d * 2 + b.l + c.f + c.i * 3 + d.f + d.i + d.d * 7;
  }
  va_end(ap);
  return s;
}

static long big(int n, ...) {
  va_list ap;
  va_start(ap, n);
  long s = 0;
  for (int k = 0; k < n; k++) {
    B24 a = va_arg(ap, B24);
    B20 b = va_arg(ap, B20);
    Pad p = va_arg(ap, Pad);
    U1 u = va_arg(ap, U1);
    s = s * 3 + a.a + a.b * 2 + a.c * 3 + b.a[0] + b.a[4] * 5 + p.c + p.s + p.i + p.l + u.u.l + u.k;
  }
  va_end(ap);
  return s;
}

// a mix of scalars and structs: registers run out in the middle of the list
static double drain(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double s = 0;
  for (int k = 0; k < n; k++) {
    int i = va_arg(ap, int);
    M1 m = va_arg(ap, M1);
    double d = va_arg(ap, double);
    I2 t = va_arg(ap, I2);
    long l = va_arg(ap, long);
    D2 q = va_arg(ap, D2);
    s += i + m.i + m.d + d + t.a + t.b + l + q.a * 2 + q.b * 3;
  }
  va_end(ap);
  return s;
}

// the same list read twice through va_copy, and handed to vsnprintf for the scalars
static int twice(const char *fmt, ...) {
  va_list ap, bp;
  va_start(ap, fmt);
  va_copy(bp, ap);
  I2 first = va_arg(ap, I2);
  M1 second = va_arg(ap, M1);
  I2 again = va_arg(bp, I2);
  char buf[64];
  va_end(ap);
  int len = vsnprintf(buf, sizeof buf, fmt, bp) * 0;   // the list is consumed by value from the struct, so print nothing
  (void)len;
  va_end(bp);
  return (int)(first.a + first.b + second.i + (long)second.d + again.a);
}

// empty classes take nothing from the list
static int empties(int n, ...) {
  va_list ap;
  va_start(ap, n);
  int s = 0;
  for (int k = 0; k < n; k++) {
    E e = va_arg(ap, E);
    (void)e;
    s += va_arg(ap, int);
  }
  va_end(ap);
  return s;
}

int main() {
  I1 i1 = {5};
  I2 i2 = {10, 20};
  C3 c3 = {{1, 2, 3}};
  F2 f2 = {1.5f, 2.5f};
  D1 d1 = {3.25};
  D2 d2 = {4.5, 5.5};
  M1 m1 = {7, 8.5};
  M2 m2 = {9.5, 11};
  M3 m3 = {1.25f, 13};
  M4 m4 = {2.5f, 14, 15.75};
  B24 b24 = {100, 200, 300};
  B20 b20 = {{1, 2, 3, 4, 5}};
  Pad pad = {'x', 300, 70000, 5000000000L};
  U1 u1 = {{42}, 43};
  D2 q = {0.5, 1.5};
  printf("ints %ld\n", ints(3, i1, i2, c3, i1, i2, c3, i1, i2, c3));
  printf("floats %g\n", floats(2, f2, d1, d2, f2, d1, d2));
  printf("mixed %g\n", mixed(2, m1, m2, m3, m4, m1, m2, m3, m4));
  printf("big %ld\n", big(2, b24, b20, pad, u1, b24, b20, pad, u1));
  printf("drain %g\n", drain(4, 1, m1, 2.5, i2, 3L, q, 4, m1, 5.5, i2, 6L, q, 7, m1, 8.5, i2, 9L, q, 10, m1, 11.5, i2, 12L, q));
  printf("twice %d\n", twice("%d", i2, m1));
  printf("empties %d\n", empties(3, E(), 4, E(), 5, E(), 6));
  printf("fold %ld\n", fold(i1));
  return 0;
}
