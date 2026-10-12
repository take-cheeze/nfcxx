// ASAN: stack-use-after-scope
// ASAN-ONLY: gcc   (qbe has no redzones for globals or stack yet: asan-plan.md, milestones 3-4)
int *leak_ptr;
int main(int argc, char **) {
  {
    int local = 5;
    leak_ptr = &local;
  }
  return *leak_ptr + argc;
}
