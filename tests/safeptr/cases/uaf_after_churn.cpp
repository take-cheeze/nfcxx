// A dangling pointer kept in a global while the program frees far more than the quarantine holds: the collector finds
// the pointer and keeps the block dead, so the late use is still found (phase 1 gave the block back and missed it).
// SAFE: use after free
#include <cstdlib>
struct Rec { long a[4]; };
Rec *keep;
int main() {
  keep = new Rec{{1, 2, 3, 4}};
  delete keep;
  for (int i = 0; i < 20000; i++) {   // more frees than the quarantine's 4096 blocks
    char *p = static_cast<char *>(std::malloc(64 + i % 32));
    p[0] = 1;
    std::free(p);
  }
  return (int)keep->a[2];
}
