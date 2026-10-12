// ASAN: attempting double-free
#include <cstdlib>
void *volatile slot;
int main() {
  slot = malloc(16);   // escapes, so the optimizer keeps both frees
  free(slot);
  free(slot);
  return 0;
}
