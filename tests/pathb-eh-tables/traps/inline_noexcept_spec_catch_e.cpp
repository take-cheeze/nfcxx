// EXPECT: 0
// STDOUT: same
// STD: c++14
#include <stdio.h>
#include <stdlib.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct D { int v; D(int x) : v(x) {} ~D() { printf("~D %d\n", v); } };
static void unex() { printf("unexpected\n"); exit(3); }
static inline int g(int x) throw(E) { if (x == 1) throw x; if (x == 2) throw E(2); return x; }
static inline int f(int x) noexcept { D d(x); return g(x) + d.v; }
static int caller(int x) {
  try { return f(x); }
  catch (E &e) { printf("caller E %d\n", e.v); return 98; }
  catch (...) { printf("caught\n"); return 99; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(2));
  return 0;
}
