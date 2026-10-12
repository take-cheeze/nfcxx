// -fsanitize=null: a load through a null pointer.
// TRAP-SANITIZE: null
// TRAP-STDERR: ubsan_null.cpp:9: runtime error: null pointer dereference
__attribute__((noinline)) int *id(int *p) { return p; }
int main() {
  int x = 1;
  int *p = id(&x);
  p = id(nullptr);
  return *p;
}
