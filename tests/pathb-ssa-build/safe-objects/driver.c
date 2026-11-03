#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void poke_slot(int i);
void poke_global(int i);
/* argv[1]: "slot" or "global"; argv[2]: the element index (0..3 is in bounds). */
int main(int argc, char **argv) {
  int i = atoi(argv[2]);
  if (strcmp(argv[1], "slot") == 0)
    poke_slot(i);
  else
    poke_global(i);
  printf("ok\n");
  return 0;
}
