// EXIT: 1
// DIAG: use-after-scope: a
int array_dangling(int i) {
  int *p;
  {
    int a[2] = {1, 2};
    p = a;
  }
  return p[i];
}
