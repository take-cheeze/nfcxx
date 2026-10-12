// -fsanitize=undefined: a function that ends without returning a value.
// TRAP-SANITIZE: undefined
// TRAP-STDERR: runtime error: execution reached the end of a value-returning function
__attribute__((noinline)) int f(int x) {
  if (x > 0) return 1;
}
int main() { return f(0); }
