// The result of an accessor of a temporary is copied after the temporary's destructor ran: the loan is still live at
// the destruction, though nothing reads the object afterwards.
// EXIT: 1
// OUT: _Z4heldv: loan-conflict: tmp (&_ZNK1S1pEv#1)
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() { int x = v; (void)x; }   // not empty: with exception tables EDG calls no destructor with an empty body
  const int *p() const { return &v; }
};
int held() {
  const int *q = S(5).p();
  const int *r = q;
  return r != 0;
}
