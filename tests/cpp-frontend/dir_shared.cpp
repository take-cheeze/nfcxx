// std::filesystem::directory_iterator holds a shared_ptr<_Dir>; its destructor must be emitted.
#include <filesystem>
#include <cstdio>
int main() {
  int n = 0;
  for (auto &e : std::filesystem::directory_iterator("/")) { (void)e; if (++n > 3) break; }
  std::printf("ok\n");
  return 0;
}
