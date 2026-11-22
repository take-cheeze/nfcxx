// EXPECT: 1
struct Base { int b; };
struct D : private Base { int d; };
int main() {
  try { throw D(); }
  catch (Base& b) { return 2; }
  catch (...) { return 1; }
}
