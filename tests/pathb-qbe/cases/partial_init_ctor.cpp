// Path B: a local array whose initializer covers only its first element, where the element type has a constructor
// (`half2 s[8] = {{0.0f, 0.0f}};` in llama.cpp's mmvf.cu). IL lowering makes the constructor calls of s[0] and has
// no statement for s[1..7], which are value-initialized: the declaration zeroes the variable first. A call before it
// leaves nonzero bytes where the array's stack slot is. The exit code is the number of wrong values.
// EXPECT: 0
#include <string.h>
struct H { unsigned short x; H() = default; H(float f) { x = (unsigned short)(f + 1); } };
struct H2 { H a, b; };
struct P { unsigned short a, b; };
__attribute__((noinline)) void dirty() { volatile char buf[512]; memset((char *)buf, 0x55, sizeof buf); }
__attribute__((noinline)) int f() {
  H2 s[8] = {{0.0f, 2.0f}};
  P p[8] = {{3, 4}};
  int bad = (s[0].a.x != 1) + (s[0].b.x != 3) + (p[0].a != 3) + (p[0].b != 4);
  for (int j = 1; j < 8; j++) bad += s[j].a.x != 0 || s[j].b.x != 0 || p[j].a != 0 || p[j].b != 0;
  return bad;
}
int main() {
  dirty();
  return f();
}
