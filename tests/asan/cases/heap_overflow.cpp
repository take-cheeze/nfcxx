// ASAN: heap-buffer-overflow
#include <cstdlib>
int main(int argc, char **) {
  int *p = new int[4];
  int r = p[3 + argc];   // one element past the end
  delete[] p;
  return r;
}
