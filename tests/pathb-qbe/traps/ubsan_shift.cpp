// -fsanitize=undefined: a shift count that is not less than the width.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_shift.cpp:6: runtime error: shift exponent is negative or not less than the width of the type
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a = 1 << id(32);
  return a;
}
