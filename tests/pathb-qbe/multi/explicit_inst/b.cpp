#include "common.h"
int b_work() {
  int a[2] = {0, 0};
  rep<16>(a, 2);
  return a[0] + a[1] + get<7>(1);
}
