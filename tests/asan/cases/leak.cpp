// ASAN: detected memory leaks
// ASAN-OPTIONS: detect_leaks=1
#include <cstdlib>
void *sink;
__attribute__((noinline)) void escape(void *p) { sink = p; }
int main() {
  escape(malloc(100));
  escape(0);   // the only pointer is gone
  return 0;
}
