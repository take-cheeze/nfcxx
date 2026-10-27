// A call of a pointer into a data object (here a heap block holding code-looking bytes).
// SAFE: call of a pointer that is not a function
#include <cstdlib>
#include <cstring>
int main() {
  unsigned char *code = static_cast<unsigned char *>(std::malloc(16));
  std::memset(code, 0xc3, 16);   // ret
  auto f = reinterpret_cast<void (*)()>(code);
  f();
  return 0;
}
