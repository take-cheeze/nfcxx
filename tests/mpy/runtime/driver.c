/* Runs the lowered module body and prints its global `result`, as the MicroPython reference prints m.result. */
#include <stdint.h>
#include <stdio.h>

typedef uint64_t mpv;

void mpy_module(void);
mpv mpy_get_global(const char *name, int *found);
void mpy_print_value(mpv v);

int main(void) {
  mpy_module();
  int found = 0;
  mpv r = mpy_get_global("result", &found);
  if (!found) {
    fprintf(stderr, "mpy: the module did not set result\n");
    return 1;
  }
  mpy_print_value(r);
  return 0;
}
