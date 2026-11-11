// A C program (no C++ runtime of its own) that dlopens a C++ shared object.
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  int (*count)(const char *) = (int (*)(const char *))dlsym(h, "cxx_count");
  int (*calls)(void) = (int (*)(void))dlsym(h, "cxx_calls");
  int (*parse)(const char *) = (int (*)(const char *))dlsym(h, "cxx_parse");
  int a = count("x"), b = count("y"), c = count("x"), e = count("");
  printf("%d %d %d %d calls %d parse %d %d\n", a, b, c, e, calls(), parse("42"), parse("zz"));
  return 0;
}
