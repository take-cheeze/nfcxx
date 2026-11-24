// EXPECT: 3
// STDOUT: same
// STD: c++14
// A noexcept function with a copy of a throw(E) callee (whose exception it cannot let out) is inlined into a function with its
// own dynamic exception specification and a catch clause: the copy's filter is std::unexpected's, and an exception the callee
// lets out of the noexcept function calls std::terminate (not traced here).
#include <stdio.h>
#include <stdlib.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
static void unex() { printf("unexpected\n"); exit(3); }
static inline int g(int x) throw(E) { if (x == 1) throw F(x); if (x == 2) throw E(2); return x; }
static inline int f(int x) noexcept { return g(x) + 1; }
static int h(int x) throw(E, F) { return f(x) + 10; }
static int caller(int x) {
  try { return h(x); }
  catch (E &e) { printf("caller E %d\n", e.v); return 98; }
  catch (...) { printf("caught\n"); return 99; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(1));
  return 3;
}
