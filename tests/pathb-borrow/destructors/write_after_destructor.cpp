// A write to an object after its destructor ran is refused: placement new would make a new object there, and the
// checker cannot tell that from a store.
// EXIT: 3
// OUT: refused: write to a destroyed C++ object (placement new is unsupported)
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() {}
};
int rewrite() {
  S s(1);
  s.~S();
  s.v = 2;
  return 0;
}
