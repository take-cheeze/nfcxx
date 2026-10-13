// ASAN: stack-buffer-overflow
// A byte past the end of a stack array whose size is not a multiple of 8: the last granule is partly addressable.
int main() {
  char c[5];
  char* p = c;
  p[4] = 1;
  p[5] = 2;
  return 0;
}
