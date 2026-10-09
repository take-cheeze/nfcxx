#include "common.h"
int b_work() {
  shared_var = 9;
  Shape s;
  return 20 + inl_add(1, 1) + tmpl_twice(2) + counter_next() + s.area() - 3;   // 20 + 2 + 4 + 2 + 0 = 28
}
