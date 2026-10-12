// std::make_shared through <memory>: pulls in std::numbers (_Float16 variables) on the qbe backend.
#include <cstdio>
#include <memory>
struct A { int x; };
int main() {
  std::shared_ptr<A> p = std::make_shared<A>();
  if (!p) return 1;
  std::printf("ok\n");
  return 0;
}
