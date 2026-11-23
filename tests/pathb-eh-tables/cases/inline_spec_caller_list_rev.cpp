// EXPECT: 0
// STDOUT: same
// STD: c++14
// The reverse: a callee with throw(B *) inlined into a caller with throw(int) and a catch (char). Its copy lets a B * out
// (the callee allows it), and the caller's specification does not allow it: std::unexpected, whose handler throws an int
// the caller allows (the caller's filter, after its catch clauses, passes it on).
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
struct K { int v; K(int x) : v(x) {} ~K() { printf("~K %d\n", v); } };
static B b9(9);
static void unex() { printf("unexpected\n"); throw 7; }
static inline int f(int x) throw(B *) { K k(x); if (x == 1) throw &b9; return x; }
static int caller(int x) throw(int) {
  try { return f(x); }
  catch (char) { printf("caller char\n"); return 1; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  std::set_unexpected(unex);
  printf("%d -> %d\n", 0, call_caller(0));
  try {
    printf("%d -> %d\n", 1, call_caller(1));
  } catch (int i) {
    printf("main int %d\n", i);
  }
  return 0;
}
