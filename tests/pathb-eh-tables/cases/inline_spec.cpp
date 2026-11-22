// EXPECT: 0
// STDOUT: same
// STD: c++14
// A callee with a dynamic exception specification (throw(T...)) is inlined into its callers when every exception that
// leaves it is one of its types (scripts/pathb-ir-opt.rb, spec_inlinable?): its throws reach the caller's handlers. A
// callee that throws another type, or runs a destructor on the way out, is not inlined: its call is std::unexpected's
// (the handler throws an allowed type, which g++ propagates the same way).
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct G { int v; G(int x) : v(x) {} ~G() { printf("~G %d\n", v); } };
static int calls;
static inline int f(int x) throw(E) { calls++; if (x > 2) throw E(x); return x * 2; }
static inline int g(int x) throw(E, F) { if (x == 1) throw F(x); return f(x) + 1; }
static inline int h(int x) throw(E) { if (x == 4) throw E(40); return 1; }
static int k(int x) throw(E) { if (x == 9) throw F(9); return 0; }
static int guard(int x) throw(E) { G gg(x); if (x == 5) throw E(50); return x; }
static void unex() { printf("unexpected\n"); throw E(7); }
int main() {
  std::set_unexpected(unex);
  int r = 0;
  for (int i = 0; i < 6; i++) {
    try { r += g(i) + h(i); } catch (E &e) { printf("E %d\n", e.v); r += 100 + e.v; } catch (F &x) { printf("F %d\n", x.v); r += 200 + x.v; }
  }
  try { r += k(9); } catch (E &e) { printf("k E %d\n", e.v); }
  try { r += guard(3); r += guard(5); } catch (E &e) { printf("guard E %d\n", e.v); r += e.v; }
  printf("calls=%d r=%d\n", calls, r);
  return 0;
}
