// Calls to a function that may throw (scripts/pathb-runtime.effects-style summary given by --effects): the
// exceptional edge leaves the function, so the normal path is checked as usual, and the summary of the caller
// is inferred as may-throw.
struct G { int v; ~G() { v = 0; } };
void may(int *p);
int callee(int c) {
  int x = 0;
  may(&x);
  return x + c;
}
int with_local(int c) {
  G g;
  g.v = c;
  int x = 0;
  may(&x);
  return g.v + x;
}
int main() {
  return callee(1) + with_local(2) - 3;
}
