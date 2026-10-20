// EXPECT: 42
// Global variables with initializers and zero initializers, a static local, a string literal and a read of a
// global table.
#include <stdio.h>
int g_count = 40;
static int g_zero;
int g_table[4] = {1, 2, 3, 4};
static int next_id(void) { static int id = 0; return ++id; }
int main(void) {
  g_zero += next_id();                   /* 1 */
  g_count += next_id();                  /* 42 */
  fputs("globals ok\n", stdout);
  return g_count + g_zero + g_table[3] - 5;   /* 42 + 1 + 4 - 5 = 42 */
}
