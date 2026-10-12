#include <cstdio>
int count_entries(const char *dir);
int main() {
  int n = count_entries("/");
  std::printf("%s\n", n > 0 ? "ok" : "empty");
  return n > 0 ? 0 : 1;
}
