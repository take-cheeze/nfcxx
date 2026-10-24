// EXIT: 0
// DIAG: local lifetime checks passed
int local_ok(bool flag) {
  int x;
  if (flag) x = 1;
  else x = 2;
  int &r = x;
  return r;
}
