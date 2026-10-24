// EXIT: 1
// DIAG: uninitialized: s[4..8]
struct Pair { int a, b; };
int field_uninitialized() {
  Pair s;
  s.a = 1;
  return s.b;
}
