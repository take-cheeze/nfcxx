// EXIT: 0
// DIAG: local lifetime checks passed
struct Pair { int a, b; };
int field_init() {
  Pair s;
  s.a = 1;
  s.b = 2;
  return s.a + s.b;
}
