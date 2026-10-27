// --emitted-only: an inline function nothing reaches is not emitted, so it is not checked. Checked, dangle
// returns a local address.
// EXIT: 0
// DIAG: ok: local lifetime checks passed
// ALL: 1
inline int *dangle() { int x = 1; return &x; }
int main() { int a = 3; int *q = &a; return *q - 3; }
