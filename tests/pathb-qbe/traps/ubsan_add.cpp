// -fsanitize=undefined: signed int overflow reports the place and aborts.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_add.cpp:7: runtime error: signed integer overflow
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a = id(2147483647);
  a = a + id(1);
  return a;
}
