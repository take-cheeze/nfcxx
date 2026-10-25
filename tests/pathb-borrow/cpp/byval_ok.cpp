// EXIT: 0
// DIAG: ok: local lifetime checks passed
// A by-value aggregate parameter is the callee's own initialized copy.
struct V { int a; int b; long c; long d; };
long byval_ok(V v) { V w = v; w.a += 1; return w.a + w.b + v.c + v.d; }
