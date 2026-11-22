// A pointer into a temporary used after the temporary's destructor ran at the end of its full expression. The
// temporary's storage lasts for the whole function, so only the destructor call ends the object. The loan of the
// accessor's result is still live at the destruction.
// EXIT: 1
// OUT: _Z8danglingv: loan-conflict: tmp (&_ZNK1S1pEv#1)
// OUT: _Z8danglingv: use-after-drop: tmp
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() { int x = v; (void)x; }   // not empty: with exception tables EDG calls no destructor with an empty body
  const int *p() const { return &v; }
};
int dangling() {
  const int *q = S(5).p();
  return *q;
}
