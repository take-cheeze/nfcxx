// -fsanitize=undefined: the step of a for loop reports the loop's line, not the last line of its body.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_loop_step.cpp:7: runtime error: signed integer overflow
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int s = 0;
  for (int i = id(2147483646); i > 0; i += id(1)) {
    s += 1;
    s -= 1;
  }
  return s;
}
