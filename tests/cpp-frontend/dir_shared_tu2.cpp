// A second translation unit that uses the same shared_ptr<_Dir> destructor: the link must keep one copy.
#include <filesystem>
int count_entries(const char *dir) {
  int n = 0;
  for (auto &e : std::filesystem::directory_iterator(dir)) { (void)e; ++n; }
  return n;
}
