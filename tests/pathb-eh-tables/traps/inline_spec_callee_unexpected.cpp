// EXPECT: 134
// TRAP-STDERR: terminate
// STDOUT: same
// STD: c++14
// A callee with throw(int) that lets a double out, inlined into a caller with throw(B *): the callee's std::unexpected (not the
// caller's) runs, and its handler's B * is not allowed by the callee's specification: std::terminate (as g++).
#include <stdio.h>
#include <exception>
struct B { int v; B(int x) : v(x) {} };
struct K { int v; K(int x) : v(x) {} ~K() { printf("~K %d\n", v); } };
static B b9(9);
static void unex() { printf("unexpected\n"); throw &b9; }
static inline int f(int x) throw(int) { K k(x); if (x == 1) throw 1.5; return x; }
static int caller(int x) throw(B *) {
  try { return f(x); }
  catch (char) { printf("caller char\n"); return 1; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  setvbuf(stdout, 0, _IONBF, 0);   // unbuffered: the output before the abort is compared
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(1));
  return 0;
}
