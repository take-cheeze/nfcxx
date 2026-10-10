// Function pointers to functions returning long double use the C calling convention: &F is the C-convention entry of F
// (its own name), so C code calls a pointer that Path B made, and Path B calls a pointer that C made. Covered: a static
// function (a local entry), an external one, a virtual function, a function defined in C, and a null-free indirect call
// with long double, int and struct arguments. c.c is built by cc (docs/notes/pathb-longdouble.md, "Calling convention").
// EXPECT: 0
#include <cstdio>

extern "C" {
long double c_apply(long double (*f)(long double, int), long double x, int k);
long double (*c_pick(int which))(long double, int);
long double c_cfun(long double x, int k);
}

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

// external, C linkage: C code refers to it
extern "C" long double cpp_mul(long double x, int k) { return x * k + 1; }

// static: its address is taken, so its C-convention entry is local
static long double scale(long double x, int k) { return x * k; }

// C++ linkage, external
long double cpp_plus(long double x, int k) { return x + k; }

struct Base {
  virtual ~Base() {}
  virtual long double value(long double x) { return x + 0.5L; }
};
struct Derived : Base {
  long double value(long double x) override { return x * 2; }
};

// Path B calls the pointer it was given, with the result pointer convention of the indirect call thunk
long double apply_cpp(long double (*f)(long double, int), long double x, int k) { return f(x, k); }

int main() {
  // a static function's address, called from C
  CHECK(c_apply(scale, 2.5L, 4) == 10.0L);
  // an external function's address, called from C
  CHECK(c_apply(cpp_mul, 2.5L, 4) == 11.0L);
  // called from Path B through a pointer that C returns (C function, and a Path B function)
  CHECK(apply_cpp(c_pick(0), 2.5L, 4) == 9.5L);
  CHECK(apply_cpp(c_pick(1), 2.5L, 4) == 11.0L);
  CHECK(apply_cpp(scale, 2.5L, 4) == 10.0L);
  CHECK(apply_cpp(cpp_plus, 2.5L, 4) == 6.5L);
  // the pointer's value is the same function's address
  long double (*p)(long double, int) = scale;
  CHECK(p(1.5L, 2) == 3.0L);
  CHECK(p == scale);
  // a C function called through a pointer that Path B made from a C symbol
  long double (*q)(long double, int) = c_cfun;
  CHECK(q(1.0L, 3) == 3.25L);
  CHECK(apply_cpp(q, 2.0L, 5) == 10.25L);
  // virtual functions: the vtable holds the C-convention address, and the call goes through the indirect call thunk
  Derived d;
  Base *b = &d;
  CHECK(b->value(3.0L) == 6.0L);
  Base plain;
  CHECK(plain.value(3.0L) == 3.5L);
  std::printf("%d\n", fails);
  return fails;
}
