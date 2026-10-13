// ASAN: stack-use-after-return
// The address of a local, used after its function has returned (no other call in between).
int* f() {
  int x = 5;
  return &x;
}
int main() {
  int* p = f();
  return *p;
}
