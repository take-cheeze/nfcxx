// ASAN: stack-use-after-scope
// continue leaves a loop body's block; the next iteration reads that block's local, through a pointer kept from it,
// before any declaration runs again.
int main(int argc, char **) {
  int *old = nullptr;
  for (int i = 0; i < 2; i++) {
    if (old) return *old;
    {
      int local = i + argc;
      old = &local;
      continue;
    }
  }
  return 0;
}
