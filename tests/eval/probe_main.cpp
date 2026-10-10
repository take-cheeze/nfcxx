// Loads the shared objects the driver built (argv[1]: C, argv[2]: C++) and calls into them.
#include <dlfcn.h>

int main(int argc, char** argv) {
  if (argc < 3) return 10;
  void* c = dlopen(argv[1], RTLD_NOW);
  void* cpp = dlopen(argv[2], RTLD_NOW);
  if (!c || !cpp) return 11;
  int (*add)(int, int) = (int (*)(int, int))dlsym(c, "probe_add");
  int (*mul)(int, int) = (int (*)(int, int))dlsym(cpp, "probe_mul");
  if (!add || !mul) return 12;
  return add(2, 3) == 5 && mul(6, 7) == 42 ? 0 : 1;
}
