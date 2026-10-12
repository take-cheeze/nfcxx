// ASAN: alloc-dealloc-mismatch
#include <cstdlib>
int main() {
  int *p = new int[2];
  delete p;   // new[] released with delete
  return 0;
}
