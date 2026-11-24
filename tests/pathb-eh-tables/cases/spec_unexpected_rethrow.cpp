// EXPECT: 0
// STDOUT: same
// STD: c++14
// A dynamic exception specification of a pointer type, and an unexpected handler that throws a type the specification
// allows: __cxa_call_unexpected rethrows that exception, and it leaves the function from the pad's call of it (a call
// site that passes it on, as gcc's: not the pads' std::terminate state). The pad's cleanups ran before the call.
#include <cstdio>
#include <exception>
struct B {
  virtual ~B() {}
};
static B b;
struct D {
  const char *n;
  ~D() { std::printf("~%s\n", n); }
};
__attribute__((noinline)) void f(int x) throw(B *) {
  D d{"f"};
  if (x == 1) throw &b;
  if (x == 2) throw 7;
}
int main() {
  std::set_unexpected([] {
    std::puts("unexpected");
    throw &b;
  });
  try {
    f(1);
  } catch (B *p) {
    std::puts(p == &b ? "f(1) threw B*" : "wrong pointer");
  }
  try {
    f(2);
  } catch (B *p) {
    std::puts(p == &b ? "the unexpected handler's B* left f(2)" : "wrong pointer");
  } catch (...) {
    std::puts("other (wrong)");
  }
  return 0;
}
