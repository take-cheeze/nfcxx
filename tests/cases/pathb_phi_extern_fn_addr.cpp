// EXPECT: 0
// Path B -> QBE: an external function chosen by a condition is a phi of two function addresses. Each is loaded from its
// pathb_got cell, and the loads must not land in the phi's block ahead of the phi (QBE: "unexpected phi instruction").
#include <cstdlib>
#include <cstring>

typedef int (*cmp_fn)(const char *, const char *);

__attribute__((noinline)) static int pick(volatile int which, const char *a, const char *b) {
  cmp_fn f = which ? strcmp : (cmp_fn)strcoll;
  int r = f(a, b);
  cmp_fn g = which > 1 ? strcoll : strcmp;
  return r + g(a, b);
}

int main() {
  if (pick(1, "a", "a") != 0) return 1;
  if (pick(0, "a", "b") >= 0) return 2;
  if (pick(2, "b", "a") <= 0) return 3;
  return 0;
}
