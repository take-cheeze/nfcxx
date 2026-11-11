// A returned pointer that may point into either argument gets a summary with two sources, and a plain call
// to it gets an implicit loan of each (--infer-summaries --infer-loan-ends).
struct Pair { int a; int b; };
static int *pick(int *x, int *y, int c) { return c ? x : y; }
static int *either(Pair *p, int c) { return c ? &p->a : &p->b; }
static void bump(int *p) { *p += 1; }
int main() {
  int x = 1, y = 2;
  bump(pick(&x, &y, 1));
  Pair s;
  s.a = 3;
  s.b = 4;
  bump(either(&s, 0));
  return x + y + s.a + s.b - 12;
}
