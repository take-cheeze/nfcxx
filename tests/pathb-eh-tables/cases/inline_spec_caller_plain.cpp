// EXPECT: 0
// STDOUT: same
// STD: c++14
// A copy with a destructor and no specification of its own (its pads have no list) inlined into a caller with throw(F): what
// leaves the copy is filtered by the caller's specification at the end of its chain (QBE's own rule for a pad without a
// list). An E leaves to std::unexpected, whose handler throws an F; a caller's catch (E) takes an E before that.
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct D { int v; D(int x) : v(x) {} ~D() { printf("~D %d\n", v); } };
static void unex() { printf("unexpected\n"); throw F(7); }
static inline int h(int x) { D d(x); if (x == 1) throw E(1); return x; }
static int caller(int x) throw(F) { return h(x) + 1; }
static int caller2(int x) throw(F) {
  try { return h(x) + 1; }
  catch (E &e) { printf("caller2 E %d\n", e.v); return 50; }
}
static int (*volatile call_caller)(int) = caller;
static int (*volatile call_caller2)(int) = caller2;
int main() {
  std::set_unexpected(unex);
  printf("0 -> %d\n", call_caller(0));
  printf("2 -> %d\n", call_caller2(1));
  try { printf("1 -> %d\n", call_caller(1)); } catch (F &f) { printf("main F %d\n", f.v); }
  return 0;
}
