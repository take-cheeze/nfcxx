// EXPECT: 1
struct Base { int b; };
struct L : Base { int l; };
struct R : Base { int r; };
struct D : L, R { int d; };
int main() {
  try { throw D(); }
  catch (Base& b) { return 2; }
  catch (...) { return 1; }
}
