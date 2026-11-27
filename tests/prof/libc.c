/* A C program for `nfcxx --profile` (tests/prof/libc.sh): the allocations made inside libc are counted in the site of
 * the call that makes them. main calls fopen and fprintf (libc mallocs the FILE and its buffer), and strdup eight times
 * (libc mallocs each copy; they are freed). alloc_some makes ten allocations of 100 bytes and frees them, and is called
 * twice, so that site has 20 allocations, 2000 bytes and 20 frees, and libc makes none of them. The file is argv[1], a
 * temporary file. */
#define _POSIX_C_SOURCE 200809L /* strdup */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *blocks[10];

__attribute__((noinline)) void alloc_some(void) {
  int i;
  for (i = 0; i < 10; i++) blocks[i] = malloc(100);
  for (i = 0; i < 10; i++) free(blocks[i]);
}

int main(int argc, char **argv) {
  FILE *f;
  char *s;
  int i;
  if (argc != 2) return 2;
  f = fopen(argv[1], "w");
  if (f == NULL) return 1;
  fprintf(f, "value %d\n", 42);
  fclose(f);
  for (i = 0; i < 8; i++) {
    s = strdup("libc");
    if (s == NULL) return 1;
    free(s);
  }
  printf("libc\n");
  alloc_some();
  alloc_some();
  return 0;
}
