// Path B: pointers to functions returning long double. The pointer holds the C-convention address of the function: a
// static one has a local entry, an external one (sqrtl of libm) is its own symbol, a virtual function's vtable slot holds
// the entry. A call through a pointer goes through the indirect call thunk, which passes the result pointer and the callee
// to the C-convention function (docs/notes/pathb-longdouble.md, "Calling convention"). The IR golden is tests/pathb-ir/ldr_ptr_ir.ir.
// EXPECT: 0
// The exit code is the number of wrong results.
// libm's sqrtl, declared here: <cmath> would also declare the _Float128 routines, which Path B refuses by name.
extern "C" long double sqrtl(long double) noexcept;

static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

static long double scale(long double x, int k) { return x * k; }
long double plus1(long double x) { return x + 1; }

struct B {
  virtual ~B() {}
  virtual long double v(long double x) { return x; }
};
struct D : B {
  long double v(long double x) override { return 2 * x; }
};

long double call_it(long double (*f)(long double, int), long double x, int k) { return f(x, k); }

int main() {
  long double (*s)(long double, int) = scale;
  CHECK(call_it(s, 1.5L, 2) == 3.0L);
  CHECK(s == scale);
  long double (*r)(long double) = ::sqrtl;
  CHECK(r(16.0L) == 4.0L);
  long double (*p1)(long double) = plus1;
  CHECK(p1(0.5L) == 1.5L);
  B *b = new D;
  CHECK(b->v(3.0L) == 6.0L);
  delete b;
  return bad;
}
