// EXPECT: 9
struct A { int a; };
struct B : A { int b; };
struct C : B { int c; };
int main() {
  try { throw C(); }
  catch (A& x) { return 9; }
  catch (...) { return 1; }
}
