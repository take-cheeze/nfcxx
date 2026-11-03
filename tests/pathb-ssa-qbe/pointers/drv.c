#include <stdio.h>
long case_main(long);
int main(void) {
  long n[] = {0, 1, 2, -3};
  for (int i = 0; i < 4; i++) printf("%ld\n", case_main(n[i]));
  return 0;
}
