// SAFE: double free
#include <cstdlib>
int main() {
  void *p = std::malloc(8);
  std::free(p);
  std::free(p);
  return 0;
}
