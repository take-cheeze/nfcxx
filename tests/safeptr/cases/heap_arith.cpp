// Pointer arithmetic that jumps from one heap block into another is caught where it is computed.
// SAFE: pointer arithmetic leaves its object
#include <cstdlib>
int main() {
  char *a = static_cast<char *>(std::malloc(16));
  char *b = static_cast<char *>(std::malloc(16));
  long d = b - a;
  char *c = a + d;   // lands in b, but has a's provenance
  *c = 1;
  return 0;
}
