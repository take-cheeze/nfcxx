// An aggregate result: the callee writes the caller's buffer (sret), summarized as init.
struct P { int a; int b; };
static P make(int x) { P p; p.a = x; p.b = x + 1; return p; }
static int sum(const P *p) { return p->a + p->b; }
int main() {
  P q = make(2);
  return sum(&q) - 5;
}
