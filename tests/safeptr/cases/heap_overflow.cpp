// Writing one element past a heap array: the pointer arithmetic is allowed (one past the end), the store is not.
// SAFE: out-of-bounds access
#include <cstdlib>
int main() {
  int *p = static_cast<int *>(std::malloc(4 * sizeof(int)));
  for (int i = 0; i <= 4; i++) p[i] = i;
  return p[0];
}
