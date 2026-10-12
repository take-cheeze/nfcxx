// ASAN: stack-use-after-scope
// A pointer to a loop body's local is kept, and the loop is left by break: the break leaves the body, so the local is out
// of scope when the pointer is read after the loop.
int *keep;
int main(int argc, char **) {
  for (int i = 0; i < 3; i++) {
    int local = i + argc;
    keep = &local;
    if (i == 1) break;
  }
  return *keep;
}
