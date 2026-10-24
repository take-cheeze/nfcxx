// EXIT: 1
// DIAG: uninitialized: a
int array_uninitialized() {
  int a[3];
  a[0] = 1; a[1] = 2;
  int t = 0;
  for (int x : a) t += x;
  return t;
}
