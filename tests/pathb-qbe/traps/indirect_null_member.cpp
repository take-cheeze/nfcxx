// The same through a function pointer stored in a struct.
struct Ops { int (*op)(int); };
__attribute__((noinline)) int run(const Ops *o, int x) { return o->op(x); }
int inc(int x) { return x + 1; }
int main() {
  Ops good = { inc };
  if (run(&good, 1) != 2) return 1;
  Ops bad = { nullptr };
  return run(&bad, 1);
}
