// An explicit destructor call ends the object: reading it afterwards, and the destructor call at its scope end, are
// errors.
// EXIT: 1
// OUT: _Z13explicit_callv: use-after-drop: s
// OUT: _Z13explicit_callv: double-drop: s
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() {}
};
int explicit_call() {
  S s(1);
  s.~S();
  return s.v;
}
