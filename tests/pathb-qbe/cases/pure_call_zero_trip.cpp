// EXPECT: 0
// IR-OPT: --hoist-pure
// A pure call in a loop that never runs must not run: first dereferences its argument, which is null here, so a hoisted
// call would trap. The loop counts come from argc (1 when run without arguments), so the trip counts are not constants.
__attribute__((noinline)) int first(const int* p) { return *p; }
int main(int argc, char**) {
  int acc = 0;
  for (int i = 0; i < argc - 1; i++) acc += first(nullptr);
  for (int i = 0; i < argc + 2; i++)
    if (i == argc + 9) acc += first(nullptr);
  return acc;
}
