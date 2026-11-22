// EXPECT: 0
// STDOUT: same
// STD: c++14
// A dynamic-spec copy inside another dynamic-spec copy: each has its own list, and the chain of the inner copy's landing pads
// has both filters in order (the inner's, then the outer's, then the caller's clauses), one per list (qbe ehspecpad K; the
// filter entries -K of ehpad). An exception that the inner allows but the outer does not goes to the outer's unexpected, not
// to the caller's catch (F); one the inner does not allow goes to the inner's.
#include <stdio.h>
#include <exception>
struct E { int v; E(int x) : v(x) {} };
struct F { int v; F(int x) : v(x) {} };
struct G { int v; G(int x) : v(x) {} };
static void unex() { printf("unexpected\n"); throw E(9); }
static inline int inner(int x) throw(E, F) { if (x == 1) throw G(1); if (x == 2) throw F(2); return x; }
static inline int middle(int x) throw(E) { return inner(x) + 10; }
static int caller(int x) {
  try { return middle(x); }
  catch (F &f) { printf("caller F %d\n", f.v); return 6; }
  catch (E &e) { printf("caller E %d\n", e.v); return 7; }
}
static int (*volatile call_caller)(int) = caller;   // called through a pointer: main's try does not take caller in
int main() {
  std::set_unexpected(unex);
  printf("%d\n", call_caller(0));
  printf("%d\n", call_caller(1));
  printf("%d\n", call_caller(2));
  return 0;
}
