// EXIT: 1
// DIAG: uninitialized: x
int uninitialized(bool flag) {
  int x;
  if (flag) x = 1;
  return x;
}
