// EXPECT: 4
struct A { int a; };
int main() {
  A x;
  const A* cp = &x;
  try { throw cp; }
  catch (A* p) { return 1; }
  catch (...) { return 4; }
}
