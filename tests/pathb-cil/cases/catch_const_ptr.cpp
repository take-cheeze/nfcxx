// EXPECT: 5
struct A { int a; };
int main() {
  A x; x.a = 5;
  const A* cp = &x;
  try { throw cp; }
  catch (A* p) { return 1; }
  catch (const A* q) { return q->a; }
  return 3;
}
