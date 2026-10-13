// -fsanitize=undefined: -INT_MIN.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_neg.cpp:6: runtime error: signed integer overflow
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a = -id(-2147483647 - 1);
  return a;
}
