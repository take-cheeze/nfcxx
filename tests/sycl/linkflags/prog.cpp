// host program for tests/sycl/linkflags: calls greet from libgreet.so
#include <cstdio>
extern "C" int greet(void);
int main() {
  if (greet() == 42) std::puts("linked ok");
  else std::puts("link failed");
  return 0;
}
