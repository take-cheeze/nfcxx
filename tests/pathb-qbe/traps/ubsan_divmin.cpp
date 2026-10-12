// -fsanitize=undefined: INT_MIN / -1.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_divmin.cpp:6: runtime error: signed integer overflow: division of the minimum value by -1
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a = id(-2147483647 - 1) / id(-1);
  return a;
}
