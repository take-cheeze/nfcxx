// EXIT: 0
// DIAG: ok: local lifetime checks passed
int array_ok() {
  int a[3];
  a[0] = 1; a[1] = 2; a[2] = 3;
  int t = 0;
  for (int x : a) t += x;
  for (int i = 0; i < 3; i++) t += a[i];
  int *p = a;
  return t + p[2] - 15;
}
