// EXPECT: 134
// TRAP-STDERR: terminate
// STD: c++14
// A noexcept function whose copy of a throw(E) callee lets E out: the noexcept function calls std::terminate, and the
// caller's catch (...) does not take the exception (the copy's list is followed by the terminate pad, not by the caller's clauses).
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
static inline int g(int x) throw(E) { if (x == 1) throw x; if (x == 2) throw E(2); return x; }
static inline int f(int x) noexcept { return g(x) + 1; }
static int caller(int x) {
  try { return f(x); }
  catch (...) { printf("caught\n"); return 99; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(2));
  return 0;
}
