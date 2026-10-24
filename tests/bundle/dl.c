// dlopen a shared object (bundled or not) and call into it: the .so-as-input case.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
static char order[64];
void note(const char *s) { strcat(order, s); }
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  int (*b_get)(void) = (int (*)(void))dlsym(h, "b_get");
  int (*a_get)(void) = (int (*)(void))dlsym(h, "a_get");
  printf("order %s b_get %d a_get %s\n", order, b_get(), a_get ? "exported" : "hidden");
  dlclose(h);
  return 0;
}
