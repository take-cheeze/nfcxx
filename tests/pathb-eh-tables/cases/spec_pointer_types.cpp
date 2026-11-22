// EXPECT: 0
// STDOUT: same
// STD: c++14
// A dynamic exception specification of types whose typeinfo nothing else in the unit makes: a class pointer, a
// class by value and a pointer to const int (the EDG fork makes each type's IA-64 typeinfo for the specification).
// Each allowed type passes; another type calls the unexpected handler, whose allowed exception passes on.
#include <cstdio>
#include <exception>
struct B { virtual ~B() {} };
struct C { int v; };
static B b;
static C c{5};
static const int ci = 9;
__attribute__((noinline)) void f(int x) throw(B *, C, const int *) {
  if (x == 1) throw &b;
  if (x == 2) throw c;
  if (x == 3) throw &ci;
  if (x == 4) throw 7;
}
__attribute__((noinline)) void g(int x) { f(x); }
int main() {
  std::set_unexpected([] { std::puts("unexpected"); throw &ci; });
  for (int x = 1; x <= 4; x++) { try { g(x); } catch (...) { std::printf("x=%d passed\n", x); } }
}
