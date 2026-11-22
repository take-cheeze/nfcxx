// EXPECT: 1
struct A { int a; };
struct D : A { int d; };
int main() {
  try { throw A(); }
  catch (D& d) { return 2; }
  catch (...) { return 1; }
}
