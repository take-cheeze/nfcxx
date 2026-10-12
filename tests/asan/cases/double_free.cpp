// ASAN: attempting double-free
#include <cstdlib>
void *sink;
__attribute__((noinline)) void escape(void *p) { sink = p; }   // the optimizer keeps both frees
int main() {
  escape(malloc(16));
  free(sink);
  free(sink);
  return 0;
}
