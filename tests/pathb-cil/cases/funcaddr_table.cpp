// EXPECT: 78
// Path B CIL spike: a static table of function addresses (data items that point at functions), indexed calls through
// it, and a comparison of two addresses of the same function. 10 -> inc 11 -> dbl 22 -> neg -22; -22 + 100 = 78, and the
// local pointer equals table[1], so no 50 is added.
static int inc(int x) { return x + 1; }
static int dbl(int x) { return x * 2; }
static int neg(int x) { return -x; }
static int (*const table[3])(int) = {inc, dbl, neg};
int main(void) {
  int (*p)(int) = dbl;
  int r = 10;
  for (int i = 0; i < 3; i++) r = table[i](r);
  return r + 100 + (p == table[1] ? 0 : 50);
}
