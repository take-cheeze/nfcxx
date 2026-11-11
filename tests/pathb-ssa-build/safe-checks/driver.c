#include <stdio.h>
#include <stdlib.h>
void poke(int *p, int i);
int main(int argc, char **argv) {
  int *p = malloc(4 * sizeof(int));
  poke(p, atoi(argv[1]));
  printf("ok\n");
  return 0;
}
