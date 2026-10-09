/* EXPECT: 0 */
/* alloca from <alloca.h> (cproc has only __builtin_alloca; bison's parsers use alloca). */
#include <alloca.h>
#include <string.h>
static int fill(int n) {
  char *p = alloca(n);
  memset(p, 'x', n);
  int sum = 0;
  for (int i = 0; i < n; i++) sum += p[i] - 'x' + 1;
  return sum;
}
int main(void) { return fill(100) == 100 ? 0 : 1; }
