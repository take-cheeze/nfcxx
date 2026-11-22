// EXPECT: 42
struct A { int a; };
struct B { int b; };
struct D : A, B { int d; };
void f() {
  try { throw D{{1}, {2}, 40}; }
  catch (B& b) { throw; }
}
int main() {
  try { f(); }
  catch (D& d) { return d.d + 2; }
  catch (...) { return 1; }
}
