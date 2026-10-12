// ASAN: stack-buffer-overflow
// ASAN-QBE: use-after-poison   (alloca's block gets the redzones of a stack object, asandynalloc)
int sink(char *p, int i) { return p[i]; }
int main(int argc, char **) {
  int n = 8 * argc + 8;   /* a multiple of 8: the redzone starts right after the object (asan.md, the granule) */
  char *p = (char *)__builtin_alloca(n);
  for (int i = 0; i < n; i++) p[i] = (char)i;
  return sink(p, n);
}
