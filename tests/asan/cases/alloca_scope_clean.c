// CLEAN
// An alloca block lives until the function returns, as C requires: reading it after its block ends is valid.
int *keep;
int main(void) {
  {
    int *p = __builtin_alloca(3 * sizeof(int));
    p[0] = 5;
    keep = p;
  }
  keep[0] += 2;
  return keep[0] == 7 ? 0 : 1;
}
