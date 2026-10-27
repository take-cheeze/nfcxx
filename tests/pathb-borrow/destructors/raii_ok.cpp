// Objects with a destructor, each ended by the destructor call EDG's lowering makes: a local at a return, a break
// and a continue, a temporary made in a loop, a class result, a temporary bound to a reference, a moved-from object
// (still a live object, destroyed at its scope end) and an object live across a throwing call caught here.
// EXIT: 0
// OUT: ok: local lifetime checks passed (supported subset only)
struct S {
  int v;
  S(int x) : v(x) {}
  S(S &&o) : v(o.v) { o.v = 0; }
  ~S() { v = -1; }
  const int *p() const { return &v; }
};
static S make(int x) { return S(x); }
static int may_throw(int x) {
  if (x < 0) throw 1;
  return x;
}
static int loop(int n) {
  int r = 0;
  for (int i = 0; i < n; i++) {
    S s(i);
    if (i == 1) continue;
    if (i == 3) break;
    r += s.v;
  }
  return r;
}
static int temporaries(int n) {
  int r = 0;
  for (int i = 0; i < n; i++) r += S(i).v + *S(1).p();
  const S &kept = S(4);
  return r + make(2).v + kept.v;
}
static int moved() {
  S a(5);
  S b(static_cast<S &&>(a));
  return a.v + b.v;
}
static int caught(int x) {
  S outer(1);
  int r = 0;
  try {
    S inner(2);
    r = may_throw(x) + inner.v;
  } catch (...) {
    r = outer.v;
  }
  return r;
}
int main() {
  int r = loop(5) + temporaries(3) + moved() + caught(-1);
  return r == 2 + 6 + 2 + 4 + 5 + 1 ? 0 : 1;
}
