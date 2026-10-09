#include <stddef.h>
static int counter;
int c_add(int a, int b) { return a + b; }
int c_bump(void) { return ++counter; }
int c_sum(const int *v, size_t n) { int s = 0; for (size_t i = 0; i < n; i++) s += v[i]; return s; }
