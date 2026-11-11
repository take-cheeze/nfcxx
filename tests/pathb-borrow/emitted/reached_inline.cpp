// --emitted-only: an inline function whose address a global holds is emitted, and checked.
// EXIT: 1
// DIAG: return-local-address: x
// ALL: 1
inline int *dangle() { int x = 1; return &x; }
int *(*keep)() = dangle;
int main() { return 0; }
