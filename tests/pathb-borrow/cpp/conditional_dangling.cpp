// EXIT: 1
// DIAG: use-after-scope: x
int conditional_dangling(int c) {
  int y = 2;
  int *p;
  {
    int x = 1;
    p = c ? &x : &y;
  }
  return *p;
}
