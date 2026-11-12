// ASAN: stack-buffer-overflow
// ASAN-PATHB: use-after-poison   (the same: the redzones of a slot in memory are poisoned at the entry, see asan.md)
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  int a[4] = {1, 2, 3, 4};
  return sink(a, 4 + argc);
}
