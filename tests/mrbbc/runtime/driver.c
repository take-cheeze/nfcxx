/* driver: the main of a program lowered by tools/mrbbc. It runs the program's entry, mrb_irep_0, and prints the value the
 * program returns the way mruby's p prints it (nil, true, false or a decimal integer). C99. */
#include <stdio.h>

#include "mrbrt.h"

extern void mrb_irep_0(MV *ret);

int main(int argc, char **argv) {
  MV ret = {MRBBC_NIL, 0};
  if (argc < 1) return 2;
  mrbbc_progname = argv[0];
  mrbbc_run(mrb_irep_0, &ret);
  mrbbc_print(&ret);
  return 0;
}
