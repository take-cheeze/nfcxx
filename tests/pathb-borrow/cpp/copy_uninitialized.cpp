// EXIT: 1
// DIAG: uninitialized: c[8..16]
struct P { char c; long l; };
struct Q { int *p; int v; };
int copy_uninitialized() {
  P a;
  a.c = 1;
  P b = a;
  P c;
  c = b;
  int x = 5;
  Q q; q.p = &x; q.v = 1;
  Q r = q;
  return c.c + (int)c.l + *r.p + r.v - 9;
}
