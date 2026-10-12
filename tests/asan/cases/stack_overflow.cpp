// ASAN: stack-buffer-overflow
// ASAN-ONLY: gcc   (qbe has no redzones for globals or stack yet: asan-plan.md, milestones 3-4)
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **) {
  int a[4] = {1, 2, 3, 4};
  return sink(a, 4 + argc);
}
