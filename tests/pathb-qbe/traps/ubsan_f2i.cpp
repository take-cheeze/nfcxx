// -fsanitize=undefined: a double that does not fit the integer type.
// TRAP-SANITIZE: float-cast-overflow
// TRAP-STDERR: ubsan_f2i.cpp:6: runtime error: value is outside the range of representable values
__attribute__((noinline)) double id(double x) { return x; }
int main() {
  int a = (int)id(1e20);
  return a;
}
