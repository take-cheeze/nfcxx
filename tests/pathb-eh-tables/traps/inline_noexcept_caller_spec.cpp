// EXPECT: 134
// TRAP-STDERR: terminate
// STDOUT: same
// STD: c++14
// A noexcept function inlined into a caller with throw(B *). Its callee g (throw(int)) lets an int out, which leaves the
// noexcept function: std::terminate, at once. The caller's specification is not checked (no std::unexpected, no B *).
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
struct K { int v; K(int x) : v(x) {} ~K() { printf("~K %d\n", v); } };
static B b9(9);
static void unex() { printf("unexpected\n"); throw &b9; }
static inline int g(int x) throw(int) { K k(x); if (x == 1) throw 2; return x; }
static inline int f(int x) noexcept { return g(x) + 1; }
static int caller(int x) throw(B *) { return f(x); }
static int (*volatile call_caller)(int) = caller;
int main() {
  setvbuf(stdout, 0, _IONBF, 0);   // unbuffered: the output before the abort is compared
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  try { printf("%d\n", call_caller(1)); } catch (B *p) { printf("main B* %d\n", p->v); }
  return 0;
}
