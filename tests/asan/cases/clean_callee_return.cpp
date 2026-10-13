// CLEAN
// A local's address is passed to a callee that returns before the caller reads the local: the callee's own locals are not
// read after it returns, and the caller's local is live until the caller returns, so nothing is reported.
#include <cstring>
static void store(int *dst, int v) {
  int tmp = v * 2;
  *dst = tmp;
}
static void fill(char *buf, int n) {
  char scratch[16];
  std::memset(scratch, 'x', sizeof scratch);
  std::memcpy(buf, scratch, n);
}
int main(int argc, char **) {
  int x = 0;
  store(&x, argc + 1);
  char name[8];
  fill(name, 4);
  name[4] = 0;
  return (x == 4 && std::strlen(name) == 4) ? 0 : 1;
}
