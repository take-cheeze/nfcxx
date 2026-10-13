// ASAN: stack-buffer-overflow
// A store one int past the end of a stack array, through a pointer (a subscript is checked by the IR's bounds node,
// which traps before any memory access, so the pointer is what reaches the shadow check).
int main() {
  int a[4];
  int* p = a;
  p[4] = 7;
  return 0;
}
