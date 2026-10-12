// CLEAN
// goto in the patterns a program uses, with no access to an object outside its scope: a backward goto out of a block
// that is declared again on each pass, a forward goto out of nested blocks to a label in an outer block, and a jump into
// a block past an uninitialized declaration (C++ allows it; the block was left in an earlier pass, so its object was
// poisoned then, and the jump has to make it addressable again).
static int again(int n) {
  int total = 0;
  int tries = 0;
again:
  {
    int local[3] = {n, n + 1, n + 2};
    int *p = local;
    total += p[2];
    if (++tries < 3) goto again;
  }
  return total;
}
static int leave(int n) {
  int acc = 0;
  for (int i = 0; i < n; i++) {
    int a = i;
    {
      int b[2] = {a, a * 2};
      if (b[1] > 6) goto done;
      acc += b[0] + b[1];
    }
  }
done:
  return acc;
}
int main(int argc, char **) {
  int n = 0, sum = 0;
  for (;;) {
    if (n == 2) break;
    if (n == 1) goto inside;
    {
      int x;
      x = 7 + argc - 1;
      sum += x;
      n = 1;
      continue;
    inside:
      x = 9;
      sum += x;
      n = 2;
    }
  }
  return sum == 16 && again(2) > 0 && leave(10) > 0 ? 0 : 1;
}
