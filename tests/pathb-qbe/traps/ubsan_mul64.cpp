// -fsanitize=undefined: a 64-bit signed product that does not fit (the emitter asks the runtime library).
// TRAP-SANITIZE: undefined
// TRAP-STDERR: ubsan_mul64.cpp:7: runtime error: signed integer overflow
__attribute__((noinline)) long id(long x) { return x; }
int main() {
  long a = id(4611686018427387904L);
  long b = a * id(2);
  return (int)b;
}
