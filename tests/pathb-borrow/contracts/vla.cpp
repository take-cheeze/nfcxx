// A lowered VLA is an ordinary pointer local: it gets (decl ...) and (scope-end ...)
// facts like any other, so the checker never refuses it for missing facts.
int f(int n) {
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  return a[n - 1];
}
int main() { return f(3) - 2; }
