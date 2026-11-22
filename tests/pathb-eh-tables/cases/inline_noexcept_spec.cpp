// EXPECT: 3
// STDOUT: same
// STD: c++14
// A noexcept function whose copy of a throw(E) callee lets another type out: the callee's std::unexpected runs (from the
// copy's filter), not the noexcept function's std::terminate. The handler exits with status 3.
#include <stdio.h>
#include <stdlib.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
static void unex() { printf("unexpected\n"); exit(3); }
static inline int g(int x) throw(E) { if (x == 1) throw x; if (x == 2) throw E(2); return x; }
static inline int f(int x) noexcept { return g(x) + 1; }
static int caller(int x) {
  try { return f(x); }
  catch (...) { printf("caught\n"); return 99; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(1));
  return 0;
}
