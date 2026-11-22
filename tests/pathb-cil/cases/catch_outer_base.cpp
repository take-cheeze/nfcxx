// EXPECT: 7
struct A { int a; };
struct B { int b; };
struct D : A, B { int d; };
int main() {
  try {
    try { throw D{{1}, {2}, 3}; }
    catch (A* p) { return 1; }
  }
  catch (B& b) { return 7; }
  return 2;
}
