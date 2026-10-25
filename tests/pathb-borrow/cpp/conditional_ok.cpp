// EXIT: 0
// DIAG: ok: local lifetime checks passed
// ?:, && and || lower to (set %r ...) on each branch.
int conditional_ok(int c) {
  int x = 1;
  int y = 2;
  int *p = c ? &x : &y;
  int z = c ? x : y;
  return ((c && z > 0) || y) ? z + *p : 0;
}
