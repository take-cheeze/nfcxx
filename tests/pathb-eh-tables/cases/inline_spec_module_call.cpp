// EXPECT: 0
// STDOUT: same
// STD: c++14
// A callee with a dynamic exception specification that calls a function of the module is inlined into a caller with no filter
// of its own, the same as any other callee of that kind (scripts/pathb-ir-opt.rb spec_copyable?): its copy keeps its landing
// pads, each with the callee's list (eh-spec-pad), so an exception that the specification does not allow goes to
// std::unexpected at the copy. Here one module call stays a call (a variadic function is refused), and another is a small
// function that may be inlined into the copy later; the call in spec_plain has no destructor, and its pad is the callee's own.
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct G { int v; G(int x) : v(x) {} ~G() { printf("~G %d\n", v); } };
static void unex() { printf("unexpected\n"); throw E(7); }
static int variadic(int a, ...) { if (a == 4) throw F(40); if (a == 5) throw E(50); return a + 1; }
static int small(int a) { if (a == 4) throw F(41); return a; }
static inline int spec_variadic(int x) throw(E) { G g(x); return variadic(x) + 1; }
static inline int spec_small(int x) throw(E) { return small(x) + 1; }
static inline int spec_plain(int x) throw(E) { return variadic(x) * 2; }
static int caller(int x) { return spec_variadic(x) + spec_small(x) + spec_plain(x); }
static int (*volatile call_caller)(int) = caller;   // called through a pointer: main's try does not take caller in
int main() {
  std::set_unexpected(unex);
  int r = 0;
  for (int i = 0; i < 7; i++) {
    try { r += call_caller(i); printf("ok %d\n", i); }
    catch (E &e) { printf("E %d\n", e.v); r += 100 + e.v; }
    catch (F &f) { printf("F %d\n", f.v); r += 200 + f.v; }
  }
  printf("r=%d\n", r);
  return 0;
}
