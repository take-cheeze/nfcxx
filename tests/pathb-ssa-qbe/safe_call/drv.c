#include <stdio.h>
#include <stdlib.h>
long case_main(long n);
int main(int argc, char **argv) {
  printf("%ld\n", case_main(atol(argv[1])));
  return 0;
}
