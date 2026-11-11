// dlopen a plugin that needs this program's libraries; the plugin's a_bump must change this program's a_counter.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
extern int a_counter;
int b_get(void);
static char order[64];
void note(const char *s) { strcat(order, s); }
int main(int argc, char **argv) {
  int before = a_counter, b = b_get();
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  int (*v)(void) = (int (*)(void))dlsym(h, "plugin_value");
  int r = v();
  printf("order %s b %d plugin %d counter %d -> %d (%s)\n", order, b, r, before, a_counter, a_counter == before + 1 ? "one libA" : "two copies of libA");
  return 0;
}
