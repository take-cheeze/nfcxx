// The dangling pointer lives in another heap block (a live std::vector's buffer), not in a global or on the stack.
// SAFE: use after free
#include <cstdlib>
#include <vector>
int main() {
  std::vector<int *> holders;
  int *x = new int(7);
  holders.push_back(x);
  delete x;
  x = nullptr;
  for (int i = 0; i < 20000; i++) delete new int[16];
  return *holders[0];
}
