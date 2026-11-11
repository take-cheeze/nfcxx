// A const pointer result aliases its argument through a shared loan (--infer-summaries).
struct Pair { int a; int b; };
static const int *second(const Pair *p) { return &p->b; }
int main() {
  Pair s;
  s.a = 1;
  s.b = 2;
  const int *q = second(&s);
  int v = *q;
  return v + s.a - 3;
}
