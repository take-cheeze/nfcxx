// CLEAN
// C input: a compound literal used inside its block (a loop body, a switch, a plain block), by address and by pointer.
struct P { int x, y; };
static int sum(const int *a, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}
int *g;
int main(int argc, char **argv) {
  int r = 0;
  (void)argv;
  for (int i = 0; i < 4; i++) {
    int *a = (int[]){i, argc, 3};
    struct P *p = &(struct P){i, 2};
    r += sum(a, 3) + p->x + p->y + sum((int[]){1, i}, 2);
    switch (i) {
    case 1:
      g = (int[]){i, 7};
      r += g[1];
      break;
    default:
      break;
    }
  }
  {
    g = (int[]){argc, 8};
    r += g[1];
  }
  return r == 0;
}
