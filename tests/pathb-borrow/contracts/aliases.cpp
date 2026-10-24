// A plain call to a returned-alias callee gets an implicit loan (--infer-summaries --infer-loan-ends).
struct Pair { int a; int b; };
static void init_pair(Pair *p, int v) { p->a = v; p->b = v + 1; }
static int sum(const Pair *p) { return p->a + p->b; }
static int *second(Pair *p) { return &p->b; }
static void bump(int *p) { *p += 1; }
int main() {
  Pair s;
  init_pair(&s, 2);
  bump(second(&s));
  return sum(&s) - 6;
}
