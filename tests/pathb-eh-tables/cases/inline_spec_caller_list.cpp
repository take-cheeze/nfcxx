// EXPECT: 0
// STDOUT: same
// STD: c++14
// A callee with throw(int) inlined into a caller with throw(B *). An int the callee allows leaves its copy: no clause of the
// caller takes it (catch (char) does not), so the caller's specification is checked there, after its catch clauses: it
// goes to std::unexpected, whose handler throws a B * the caller allows. caller2's catch (int) takes the same int first.
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
struct K { int v; K(int x) : v(x) {} ~K() { printf("~K %d\n", v); } };
static B b9(9);
static void unex() { printf("unexpected\n"); throw &b9; }
static inline int f(int x) throw(int) { K k(x); if (x == 1) throw 2; return x; }
static int caller(int x) throw(B *) {
  try { return f(x); }
  catch (char) { printf("caller char\n"); return 1; }
}
static int caller2(int x) throw(B *) {
  try { return f(x); }
  catch (int i) { printf("caller2 int %d\n", i); return 100 + i; }
}
static int (*volatile call_caller)(int) = caller;   // called through a pointer: main's try does not take caller in
static int (*volatile call_caller2)(int) = caller2;
int main() {
  std::set_unexpected(unex);
  printf("%d -> %d\n", 0, call_caller(0));
  printf("%d -> %d\n", 2, call_caller2(1));
  try {
    printf("%d -> %d\n", 1, call_caller(1));
  } catch (B *p) {
    printf("main B* %d\n", p->v);
  }
  return 0;
}
