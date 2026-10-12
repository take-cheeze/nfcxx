// ASAN: stack-use-after-return
// A pointer to a local of a function is kept past the return of that function: the local lives in a fake frame (libasan's
// fake stack; qbe: __asan_stack_malloc_N at the entry, __asan_stack_free_N at the return), which the return poisons, so
// the read after it reports. The read is in main, the frame of leak_local has returned (detect_stack_use_after_return is
// on by default in libasan).
int *leak_ptr;
__attribute__((noinline)) static void leak_local(int v) {
  int local = v;
  leak_ptr = &local;
}
int main(int argc, char **) {
  leak_local(argc + 4);
  return *leak_ptr;
}
