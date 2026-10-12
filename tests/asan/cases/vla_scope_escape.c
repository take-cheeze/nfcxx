// ASAN: stack-use-after-scope
// ASAN-ONLY: qbe   (gcc does not instrument the scope of a variable-length array; cproc does)
// A variable-length array's lifetime ends with its block: a pointer to it read after the block, in the same function, is
// an error. (Reading it after the function returned is use-after-return, which is not covered.)
static int grab(int n) {
  int *p;
  {
    int v[n];
    v[0] = 7;
    p = v;
  }
  return *p;
}
int main(int argc, char **argv) {
  return grab(argc + 3);
}
