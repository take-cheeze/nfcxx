#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
struct Thrower { int v; };
int f(int x) { if (x > 2) throw Thrower{x}; return x; }
int main() {
  int caught = 0;
  for (int i = 0; i < 5; ++i) {
    try { f(i); } catch (const Thrower& t) { caught += t.v; }
  }
  try { throw std::runtime_error("boom"); } catch (const std::exception& e) { std::printf("what=%s\n", e.what()); }
  std::vector<std::string> v;
  for (int i = 0; i < 100; ++i) v.push_back(std::string(20, 'a' + i % 26));
  int* p = new int[1000]; p[999] = 7; int r = p[999]; delete[] p;
  std::printf("caught=%d size=%zu r=%d\n", caught, v.size(), r);
  return caught == 7 ? 0 : 1;
}
