// EXIT: 1
// DIAG: uninitialized: x
int conditional_uninitialized(int c) {
  int x;
  int y = 2;
  return c ? x : y;
}
