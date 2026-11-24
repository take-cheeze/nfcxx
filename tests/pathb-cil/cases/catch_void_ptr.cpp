// EXPECT: 9
struct A { int a; };
struct D : A { int d; };
int main() {
  D d;
  try { throw &d; }
  catch (int* p) { return 1; }
  catch (void* v) { return v == (void*)&d ? 9 : 2; }
  return 3;
}
