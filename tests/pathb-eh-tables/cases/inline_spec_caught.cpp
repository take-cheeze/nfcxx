// EXPECT: 0
// STDOUT: same
// STD: c++14
// A callee with a dynamic exception specification that throws another type (spec_inlinable? refuses it) is inlined into a
// caller with catch clauses: its copy's landing pads filter with the callee's list before the caller's catch clauses, so an
// exception the callee does not allow goes to std::unexpected, not to the caller's catch (qbe ehspecpad N). An allowed one
// goes on to the caller's catch clauses (B *: the caller's). The unexpected handler's B * is taken by that clause too.
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
static B b9(9);
static void unex() { printf("unexpected\n"); throw &b9; }
static inline void f(int x) throw(B *) { if (x == 1) throw x; if (x == 2) throw &b9; }
static int caller(int x) {
  try { f(x); return 0; }
  catch (int) { printf("caught int\n"); return 1; }
  catch (B *p) { printf("caller B* %d\n", p->v); return 2; }
}
static int (*volatile call_caller)(int) = caller;   // called through a pointer: main's try does not take caller in
int main() {
  std::set_unexpected(unex);
  int r = call_caller(0);
  printf("0 -> %d\n", r);
  r = call_caller(2);   // allowed by f: the caller's catch takes it
  printf("2 -> %d\n", r);
  r = call_caller(1);   // not allowed: unexpected throws &b9, which the caller's catch takes; its catch (int) is not reached
  printf("1 -> %d\n", r);
  return r == 2 ? 0 : 1;
}
