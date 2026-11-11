// A temporary made on one branch of ?: is destroyed under EDG's flag test after the expression. The checker does not
// correlate the flag with the branch, so the destructor may run on an object never made: refused.
// EXIT: 3
// OUT: refused: destructor of a C++ object not registered on every path
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() {}
};
int conditional(bool c) { return c ? S(1).v : 0; }
