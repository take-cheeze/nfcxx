// A call through a function pointer of another type: the callee takes a pointer, the caller passes an int.
// SAFE: call through a function pointer of the wrong type
#include <cstdio>
static int deref(const int *p) { return *p; }
using IntFn = int (*)(int, int);
int main(int argc, char **) {
  IntFn f = reinterpret_cast<IntFn>(&deref);
  return f(argc, 2);
}
