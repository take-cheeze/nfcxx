// EXPECT: 0
// STDOUT: same
// STD: c++14
// A callee with a dynamic exception specification (throw(T...)) that spec_inlinable? refuses (it throws another type, runs a
// destructor on the way out, or calls a function that may throw anything) is inlined into a caller with no catch clause: its
// copy's landing pads carry the callee's own list (eh-spec-pad, QBE's ehspecpad), so an exception it does not allow goes to
// std::unexpected at the copy, and an allowed one goes on to the caller's cleanups and handlers (scripts/pathb-ir-opt.rb).
// A caller that has a filter already (a copy with one, or its own specification) is not given another copy with one: the
// pads of that copy would resume past the caller's filter. So spec_caller keeps its call, and so do the copies that
// would need one under a filter.
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct G { int v; G(int x) : v(x) {} ~G() { printf("~G %d\n", v); } };
static void unex() { printf("unexpected\n"); throw E(7); }
static inline int bad(int x) throw(E) { if (x == 1) throw F(x); return x; }
static inline int guard(int x) throw(E) { G gg(x); if (x == 2) throw E(20); if (x == 3) throw F(30); return x; }
static int thrower(int x) { if (x == 4) throw F(40); if (x == 5) throw E(50); return x; }
static inline int spec_calls(int x) throw(E) { return thrower(x) + 1; }
static inline int allows_f(int x) throw(F) { G g(x); if (x == 2) throw F(2); return x; }
static int spec_caller(int x) throw(E) { return allows_f(x) + 1; }   // F is not E: allows_f's copy would call unexpected
static int caller(int x) { return bad(x) + guard(x) + spec_calls(x) + spec_caller(x); }
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
