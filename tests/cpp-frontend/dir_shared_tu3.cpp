// A third unit with the same destructor; with the two others it links to one copy of each destructor.
#include <filesystem>
int first_is_dir(const char *dir) {
  auto it = std::filesystem::directory_iterator(dir);
  return it == std::filesystem::directory_iterator() ? 0 : 1;
}
