// A local with a destructor: EDG's lowering pushes and pops exception-stack
// frames around it, and calls the destructor (a const this parameter).
struct G { int v; ~G() { v = 0; } };
static int get(const G *g) { return g->v; }
int main() {
  int r;
  const G *k;
  {
    G g;
    g.v = 3;
    k = &g;
    r = get(k);
  }
  return r - 3;
}
