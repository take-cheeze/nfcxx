// ASAN: global-buffer-overflow
// A byte past the end of a global array whose size is not a multiple of 8.
char c[5];
int main() {
  char* p = c;
  p[4] = 1;
  p[5] = 2;
  return 0;
}
