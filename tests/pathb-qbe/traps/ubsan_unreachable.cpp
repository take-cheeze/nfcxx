// -fsanitize=undefined: __builtin_unreachable() is reached.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_unreachable.cpp:7: runtime error: execution reached an unreachable program point
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  if (id(1) == 1)
    __builtin_unreachable();
  return 0;
}
