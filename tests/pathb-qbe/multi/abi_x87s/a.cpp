// A struct of 16 bytes whose only member is a long double is class X87 in the System V ABI: an argument goes in memory
// (on the stack, 16-byte aligned) and a result comes back in st(0), exactly as a long double does. The struct crosses the
// C boundary in both directions, nested, with integer arguments that fill the registers, and through function pointers.
// c.c is built by cc (docs/notes/pathb-longdouble.md).
// EXPECT: 0
#include <cstdio>

struct W { long double x; };
struct Wn { W inner; };

extern "C" {
W c_make(long double v);
long double c_sum(W a, int k, W b);
W c_pass(W a, W b);
Wn c_nested(Wn a);
W c_call_make(W (*f)(long double), long double v);
long double c_many(int a, int b, int c, int d, int e, int f, W w, long double x, W v);
}

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

W cpp_make(long double v) { W w; w.x = v; return w; }
long double cpp_sum(W a, int k, W b) { return a.x * k + b.x; }
W cpp_twice(W a) { W r; r.x = a.x * 2; return r; }
long double cpp_many(int a, int b, int c, int d, int e, int f, W w, long double x, W v) {
  return a + b + c + d + e + f + w.x + x + v.x;
}

int main() {
  // C makes a W (returned in st(0)), Path B reads it
  CHECK(c_make(1.5L).x == 1.5L);
  // Path B passes W in memory; C reads it and returns a long double
  CHECK(c_sum(cpp_make(2.0L), 3, cpp_make(0.5L)) == 6.5L);
  // both directions in one call: C returns a W that Path B takes apart
  W p = c_pass(cpp_make(4.0L), cpp_make(1.0L));
  CHECK(p.x == 9.0L);
  // nested struct: Wn is also class X87
  Wn n;
  n.inner.x = 7.25L;
  CHECK(c_nested(n).inner.x == 8.25L);
  // Path B calls C through a pointer that C takes
  W (*fp)(long double) = cpp_make;
  CHECK(fp(3.0L).x == 3.0L);
  CHECK(c_call_make(fp, 2.25L).x == 2.25L);
  // integer registers used up: the W arguments are on the stack, behind the long double
  CHECK(c_many(1, 2, 3, 4, 5, 6, cpp_make(0.5L), 0.25L, cpp_make(8.0L)) == 1 + 2 + 3 + 4 + 5 + 6 + 0.5L + 0.25L + 8.0L);
  CHECK(cpp_many(1, 2, 3, 4, 5, 6, cpp_make(0.5L), 0.25L, cpp_make(8.0L)) == 1 + 2 + 3 + 4 + 5 + 6 + 0.5L + 0.25L + 8.0L);
  std::printf("%d\n", fails);
  return fails;
}
