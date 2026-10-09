// EXPECT: 17
// SOURCES: mixed.cpp mixed_c.c
// Mixed C + C++: C++ calls C functions declared extern "C".
#include <stddef.h>
extern "C" {
int c_add(int a, int b);
int c_bump(void);
int c_sum(const int *v, size_t n);
}
int main() {
  int v[3] = {1, 2, 3};
  c_bump();
  return c_add(2, 3) + c_bump() + c_sum(v, 3) + 4;   // 5 + 2 + 6 + 4
}
