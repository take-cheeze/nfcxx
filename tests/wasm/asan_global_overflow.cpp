// ASAN: global-buffer-overflow
// A store one int past the end of a global array, through a pointer.
int g[4];
int main() {
  int* p = g;
  p[4] = 7;
  return 0;
}
