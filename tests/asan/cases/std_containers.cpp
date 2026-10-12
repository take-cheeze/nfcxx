// ASAN: heap-buffer-overflow
// std::vector's storage is checked too: operator[] has no bounds check.
#include <vector>
int main(int argc, char **) {
  std::vector<int> v(4, 1);
  return v[4 + argc - 1];
}
