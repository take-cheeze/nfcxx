// CLEAN
// A return before a variable-length array's declaration must not poison it: the redzones are poisoned at the declaration
// (as a stack object's are), so the early return leaves nothing behind. Later calls reuse the same stack.
static int f(int n, int early) {
  if (early) return 7;
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  return a[n - 1];
}
static int g(int n) {
  char buf[256];
  for (int i = 0; i < 256; i++) buf[i] = (char)(i + n);
  return buf[255];
}
int main(void) {
  int s = 0;
  for (int i = 0; i < 100; i++) {
    s += f(i % 9 + 1, 1);
    s += f(i % 9 + 1, 0) + g(i);
  }
  return s != 0 ? 0 : 1;
}
