/* Hosted executable entry: the Ruby program owns stdout and its arguments. The value of its last expression is ignored. */
#include "mrbrt.h"
extern void mrb_irep_0(MV *ret);
int main(int argc, char **argv) {
  MV ret = {0};
  if (argc < 1) return 2;
  mrbbc_progname = argv[0];
  mrbbc_set_args(argc, argv);
  mrbbc_run(mrb_irep_0, &ret);
  return 0;
}
