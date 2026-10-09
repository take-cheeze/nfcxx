// EXPECT: 237
// Control flow: switch with fallthrough, a default in the middle and a case inside a block; continue (a goto in
// the IR), break, goto, do-while, short-circuit operators with side effects, ?: and the comma operator.
__attribute__((noinline)) int sw(int k) {
  int r = 0;
  switch (k) {
    case 1: r += 1;
    case 2: r += 10; break;
    default: r += 100;
    case 3: r += 1000; break;
    case 7: { r += 5; }
  }
  return r;
}
__attribute__((noinline)) int loops(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) {
    if (i == 3) continue;
    if (i == 6) break;
    s += i;
  }
  int j = 0;
  do { s += 100; } while (++j < 2);
  int k = 0;
again:
  if (k < 3) { ++k; goto again; }
  return s + k;
}
static int calls = 0;
__attribute__((noinline)) bool touch(bool v) { ++calls; return v; }
int main() {
  if (sw(1) + sw(2) + sw(3) + sw(7) + sw(9) != 2126) return 1;
  int t = 0;
  bool a = touch(false) && touch(true);
  bool b = touch(true) || touch(true);
  t += a + b;
  int c = (calls > 1) ? 10 : 20;
  int d = (touch(false), 5);
  t += c + d;
  int q = 0;
  for (int i = 0; i < 4; ++i) {
    switch (i) { case 2: break; default: q += 1; }
  }
  t += q;
  return t + loops(10) + calls;
}
