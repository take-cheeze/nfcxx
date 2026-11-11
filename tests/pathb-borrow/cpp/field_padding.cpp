// EXIT: 0
// DIAG: local lifetime checks passed
struct Pad { char a; int b; };
int field_padding() {
  Pad s;
  s.a = 1;
  s.b = 2;
  Pad &r = s;
  return r.a + r.b;
}
