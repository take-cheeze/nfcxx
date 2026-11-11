// EXIT: 0
// DIAG: ok: local lifetime checks passed
// Aggregate copies carry byte states (padding stays uninitialized) and pointer fields.
struct P { char c; long l; };
struct Q { int *p; int v; };
int copy_ok() {
  P a;
  a.c = 1; a.l = 2;
  P b = a;
  P c;
  c = b;
  int x = 5;
  Q q; q.p = &x; q.v = 1;
  Q r = q;
  return c.c + (int)c.l + *r.p + r.v - 9;
}
