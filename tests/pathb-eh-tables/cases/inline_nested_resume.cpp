// EXPECT: 0
// STDOUT: same
// A callee with a cleanup pad inlined inside another inlined copy (inner's copy in middle's, both in outer): inner's pad
// resumes into the pad of middle's copy, which keeps the exception in that copy's slots, not in outer's.
#include <cstdio>
struct D {
  const char *n;
  ~D() { std::printf("~%s\n", n); }
};
static int depth;
__attribute__((noinline)) static void thrower(int x) {
  if (x > 0) throw x;
}
static inline void inner(int x) {
  D d{"inner"};
  ++depth;
  thrower(x);
}
static inline void middle(int x) {
  D d{"middle"};
  if (x > 1) inner(x);
  inner(x - 1);
}
int outer(int x) {
  D d{"outer"};
  try {
    middle(x);
  } catch (int e) {
    std::printf("caught %d at depth %d\n", e, depth);
    return e;
  }
  return 0;
}
int main() { return outer(3) == 3 && outer(1) == 0 ? 0 : 1; }
