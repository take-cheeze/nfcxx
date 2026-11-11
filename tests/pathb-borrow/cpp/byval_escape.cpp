// EXIT: 1
// DIAG: return-local-address: *%0
struct V { int a; int b; long c; long d; };
const int *byval_escape(V v) { return &v.a; }
