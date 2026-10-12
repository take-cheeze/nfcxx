// ASAN: detected memory leaks
// ASAN-OPTIONS: detect_leaks=1
#include <cstdlib>
void *volatile sink;
int main() {
  sink = malloc(100);
  sink = 0;   // the only pointer is gone
  return 0;
}
