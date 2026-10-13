// EXPECT: 42
// A pointer parameter and a pointer result of an exported function. Under --emscripten (ILP32) they are i32, so
// emscripten.cjs can call ident with an address as a Number and get one back. The result is the same under LP64.
extern "C" int *ident(int *p) { return p; }
int main() {
  int x = 42;
  int *q = ident(&x);
  return *q;
}
