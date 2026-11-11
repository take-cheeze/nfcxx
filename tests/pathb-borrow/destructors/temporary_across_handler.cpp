// A temporary bound to a reference is live at a throw caught in the same function. Its storage spans the function,
// so the checker cannot tell whether the unwind destroyed it (made inside the try block) or not: refused.
// EXIT: 3
// OUT: refused: a live C++ temporary at a throw into a handler of the function
struct S {
  int v;
  S(int x) : v(x) {}
  ~S() {}
};
static int may_throw(int x) {
  if (x < 0) throw 1;
  return x;
}
int across(int x) {
  const S &kept = S(1);
  int r = 0;
  try {
    r = may_throw(x);
  } catch (...) {
    r = -1;
  }
  return r + kept.v;
}
