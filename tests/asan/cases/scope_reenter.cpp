// CLEAN
// A block entered again and again (a loop body, a for-init declaration) makes its locals addressable each time the
// declaration is reached: the block's end poisons them and the declaration unpoisons them.
static int run(int n) {
  int total = 0;
  for (int i = 0; i < n; i++) {
    int a[4];
    char c = (char)i;
    int *p = &a[0];
    for (int j = 0; j < 4; j++) p[j] = i + j;
    c += 1;
    total += a[3] + c;
  }
  for (int k = 0; k < n; k++) {
    int x = k;
    int *q = &x;
    *q += 1;
    total += x;
  }
  return total;
}
int main() {
  return run(100) > 0 ? 0 : 1;
}
