// EXPECT: 42
struct A { int a; };
struct B { int b; };
struct D : A, B { int d; };
int main() {
  D d; d.b = 42;
  try { throw &d; }
  catch (B* q) { return q->b; }
  catch (...) { return 1; }
}
