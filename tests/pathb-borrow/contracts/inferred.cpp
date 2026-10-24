// Callers checked against summaries inferred from the callee bodies (--infer-summaries).
struct Pair { int a; int b; };
static void init_pair(Pair *p, int v) { p->a = v; p->b = v + 1; }
static int sum(const Pair *p) { return p->a + p->b; }
static void bump(int *p) { *p += 1; }
int main() {
  Pair s;
  init_pair(&s, 2);
  int c = 0;
  bump(&c);
  return sum(&s) + c - 6;
}
