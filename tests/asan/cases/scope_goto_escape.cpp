// ASAN: stack-use-after-scope
// A backward goto leaves a block, and the label reads the block's local through a pointer kept from the block. EDG
// lowers the C++ goto to a label of its own, so this is the path the C++ break and continue take too.
int main(int argc, char **) {
  int n = 0;
  int *old = nullptr;
again:
  if (old) return *old;
  {
    int local = 7 + argc;
    old = &local;
    if (++n < 2) goto again;
  }
  return 0;
}
