// EXPECT: 54
// Two translation units (a.cpp, b.cpp) include common.h and are linked together.
// The counter and shared_var must be one object across both units: counter 1, then b's call 2, then 3.
#include "common.h"
int b_work();   // b.cpp: calls counter_next() once, sets shared_var to 9, returns 28
int main() {
  int r = inl_add(2, 3);               // 5
  r += tmpl_twice(4);                  // 8
  r += counter_next();                 // 1
  r += b_work();                       // 28
  r += counter_next();                 // 3
  r += shared_var;                     // 9
  Shape s;
  r += s.area() - 3;                   // 0
  return r;                            // 5 + 8 + 1 + 28 + 3 + 9 + 0 = 54
}
