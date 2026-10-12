// CLEAN
// A program with no memory error runs to completion under asan, exceptions and the standard library included.
#include <cstdio>
#include <map>
#include <string>
#include <vector>
struct Err { int code; };
static int thrower(int n) {
  std::string guard = "guard-" + std::to_string(n);   // destroyed or freed on the throw path
  if (n > 2) throw Err{n};
  return (int)guard.size();
}
int main() {
  std::map<std::string, std::vector<int>> m;
  for (int i = 0; i < 100; i++) m["k" + std::to_string(i % 7)].push_back(i);
  int sum = 0;
  for (auto &kv : m) for (int x : kv.second) sum += x;
  try { thrower(5); } catch (Err &e) { sum += e.code; }
  std::printf("%d\n", sum);
  return sum == 4955 ? 0 : 1;
}
