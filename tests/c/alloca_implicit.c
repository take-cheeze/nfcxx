/* EXPECT: 0 */
/* alloca without <alloca.h> is implicitly declared (returning int, as K&R C has it). gcc treats it as the built-in and
   its result is a 64-bit pointer; the implicit int must not cut a stack address (Path B once did: a crash in ASTro's
   luastro, sample/luastro/node.def). */
#include <stdio.h>
#include <string.h>
static long sum(int n) {
  int *a = (int *)alloca(n * sizeof(int));
  long s = 0;
  int i;
  for (i = 0; i < n; i++) a[i] = i + 1;
  for (i = 0; i < n; i++) s += a[i];
  return s;
}
int main(int argc, char **argv) {
  char *p = (char *)alloca(argc + 40);
  long q = (long)alloca(16);
  void *v;
  int bad = 0;
  strcpy(p, "alloca works");
  bad += strcmp(p, "alloca works") != 0;
  bad += sum(10) != 55;
  bad += q == 0;
  v = alloca(8);
  bad += v == 0 || (char *)v == p;
  return bad;
}
