// -fsanitize=undefined: an index past the end of an array.
// TRAP-SANITIZE: bounds
// TRAP-STDERR: ubsan_bounds.cpp:7: runtime error: index out of bounds for the array
__attribute__((noinline)) int id(int x) { return x; }
int main() {
  int a[4] = {1, 2, 3, 4};
  return a[id(4)];
}
