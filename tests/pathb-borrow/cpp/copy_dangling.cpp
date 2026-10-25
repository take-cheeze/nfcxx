// EXIT: 1
// DIAG: use-after-scope: x
struct Q { int *p; int v; };
int copy_dangling() {
  Q r;
  {
    int x = 5;
    Q q; q.p = &x; q.v = 1;
    r = q;
  }
  return *r.p;
}
