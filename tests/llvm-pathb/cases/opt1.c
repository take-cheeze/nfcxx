// OPT: 1
// EXPECT: 110
// Optimized input (clang -O1): phi nodes and select. The swap loop has phis that read each other, which needs
// the parallel copy of the translator.
int pick(int a, int b, int c) { return a > b ? a + c : b - c; }
int loop(int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s = s < i ? i : s + 2;
  return s;
}
int swap(int n) {
  int a = 1, b = 2;
  for (int i = 0; i < n; i++) { int t = a; a = b; b = t; }
  return a * 10 + b;
}
int fibi(int n) {
  int a = 0, b = 1;
  for (int i = 0; i < n; i++) { int t = a + b; a = b; b = t; }
  return a;
}
int main(void) { return pick(7, 3, 2) + pick(1, 9, 4) + loop(10) + swap(3) + fibi(10); }
