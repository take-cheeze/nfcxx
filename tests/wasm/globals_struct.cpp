// EXPECT: 38
// A global struct whose pointer member points at another global (an address item), and a global of a short type
// placed after a char so that alignment matters.
struct Inner { int a; int b; };
struct Outer { int k; Inner *p; };
Inner in = {5, 7};
char c = 1;
short sh = 2;
Outer o = {3, &in};
int main() {
  return o.k + o.p->a * o.p->b + c + sh - 3 + 0 * sh;   // 3 + 35 + 1 + 2 - 3 = 38
}
