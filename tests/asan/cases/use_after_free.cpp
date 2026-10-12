// ASAN: heap-use-after-free
#include <cstdlib>
struct S { int v; S() : v(7) {} };
int main() {
  S *s = new S;
  delete s;
  return s->v;
}
