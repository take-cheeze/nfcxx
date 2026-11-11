#include <mruby.h>
#include "demo_value.h"

static mrb_value
demo_value(mrb_state *mrb, mrb_value self)
{
  return mrb_fixnum_value(DEMO_VALUE);
}

void
mrb_mruby_generated_demo_gem_init(mrb_state *mrb)
{
  struct RClass *m = mrb_define_module(mrb, "GeneratedDemo");
  mrb_define_module_function(mrb, m, "value", demo_value, MRB_ARGS_NONE());
}

void
mrb_mruby_generated_demo_gem_final(mrb_state *mrb)
{
}
