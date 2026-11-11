#include <stdio.h>
int alloca_sum(int n);
int volatile_id(int n);
int main(void) {
  printf("%d %d %d\n", alloca_sum(8), alloca_sum(1), volatile_id(6));
  return 0;
}
