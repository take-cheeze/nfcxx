// SAFE: out-of-bounds access
#include <cstring>
#include <cstdlib>
int main(int argc, char **) {
  char *dst = static_cast<char *>(std::malloc(8));
  const char src[] = "0123456789abcdef";
  std::memcpy(dst, src, 8 + argc);
  return dst[0];
}
