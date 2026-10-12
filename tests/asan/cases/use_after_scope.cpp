// ASAN: stack-use-after-scope
// A pointer to a block's local is kept past the block: the block's end poisons the local (qbe: asanend, gcc: its own
// instrumentation), so the read after it reports.
int *leak_ptr;
int main(int argc, char **) {
  {
    int local = 5;
    leak_ptr = &local;
  }
  return *leak_ptr + argc;
}
