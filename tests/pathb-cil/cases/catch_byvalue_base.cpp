// EXPECT: 33
struct A { int a; };
struct B { int b; };
struct D : A, B { int d; };
int main() {
  D d; d.a = 1; d.b = 2; d.d = 30;
  try { throw d; }
  catch (B b) { return b.b + b.b * 0 + 31; }
  catch (...) { return 1; }
}
