// EXIT: 1
// DIAG: use-after-scope: s
struct Pair { int a, b; };
int field_dangling() {
  int *p;
  { Pair s; s.a = 1; s.b = 2; p = &s.b; }
  return *p;
}
