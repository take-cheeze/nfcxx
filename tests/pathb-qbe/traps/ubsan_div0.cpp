// -fsanitize=undefined: division by zero.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_div0.cpp:6: runtime error: division by zero
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a = 10 / id(0);
  return a;
}
