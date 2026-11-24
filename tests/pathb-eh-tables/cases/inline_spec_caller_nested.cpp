// EXPECT: 0
// STDOUT: same
// STD: c++14
// Two dynamic-spec copies inside a caller with a specification of its own (throw(E)): middle (throw(E)) has inner (throw(E, F))
// inside it, and inner has a destructor. The copies' chains take their own lists and then the caller's filter: an F that inner
// allows and middle does not goes to middle's std::unexpected (the handler throws an E the specifications allow), not to the
// caller's catch (F). A G that inner does not allow goes to inner's.
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct G { int v; G(int x) : v(x) {} };
struct D { int v; D(int x) : v(x) {} ~D() { printf("~D %d\n", v); } };
static void unex() { printf("unexpected\n"); throw E(9); }
static inline int inner(int x) throw(E, F) { D d(x); if (x == 1) throw G(1); if (x == 2) throw F(2); return x; }
static inline int middle(int x) throw(E) { return inner(x) + 10; }
static int caller(int x) throw(E) {
  try { return middle(x); }
  catch (F &f) { printf("caller F %d\n", f.v); return 6; }
}
static int (*volatile call_caller)(int) = caller;
int main() {
  std::set_unexpected(unex);
  printf("0 -> %d\n", call_caller(0));
  try { printf("2 -> %d\n", call_caller(2)); } catch (E &e) { printf("main E %d\n", e.v); }
  try { printf("1 -> %d\n", call_caller(1)); } catch (E &e) { printf("main E %d\n", e.v); }
  return 0;
}
