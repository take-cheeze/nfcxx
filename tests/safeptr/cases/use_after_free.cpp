// SAFE: use after free
#include <cstdlib>
struct S { int x, y; };
int main() {
  S *s = new S{1, 2};
  delete s;
  return s->y;
}
