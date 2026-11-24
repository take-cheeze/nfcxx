// EXPECT: 134
// TRAP-STDERR: terminate
// STDOUT: same
// STD: c++14
// A noexcept function inlined into a caller with throw(B *) that throws an int itself (no copy of a callee): the int leaves the
// noexcept function, so std::terminate runs; the caller's specification (and its std::unexpected) is not reached.
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
static B b9(9);
static void unex() { printf("unexpected\n"); throw &b9; }
static inline int f(int x) noexcept { if (x == 1) throw 2; return x; }
static int caller(int x) throw(B *) { return f(x); }
static int (*volatile call_caller)(int) = caller;
int main() {
  setvbuf(stdout, 0, _IONBF, 0);   // unbuffered: the output before the abort is compared
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  try { printf("%d\n", call_caller(1)); } catch (B *p) { printf("main B* %d\n", p->v); }
  return 0;
}
