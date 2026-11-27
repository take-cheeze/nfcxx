/* A C program for `nfcxx --profile` (tests/prof/sqlite.sh): the allocation counts of each site. grab_blocks makes exactly five
 * allocations of 64 bytes and is called twice, so that site has 10 allocations, 640 bytes and no frees. release_blocks frees
 * the ten blocks, so that site has 10 frees and no allocations. The functions are global so the profile names them. */
#include <stdio.h>
#include <stdlib.h>

static void *blocks[10];

__attribute__((noinline)) void grab_blocks(int first) {
  int i;
  for (i = 0; i < 5; i++) blocks[first + i] = malloc(64);
}

__attribute__((noinline)) void release_blocks(void) {
  int i;
  for (i = 0; i < 10; i++) free(blocks[i]);
}

int main(void) {
  grab_blocks(0);
  grab_blocks(5);
  release_blocks();
  printf("%d\n", 10);
  return 0;
}
