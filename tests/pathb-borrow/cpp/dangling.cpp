// EXIT: 1
// DIAG: use-after-scope: x
int dangling() {
  int *p;
  { int x = 1; p = &x; }
  return *p;
}
