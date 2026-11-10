/*
** mruby_env_world.c - ENV for the script-world closed build (tools/script_world/env_world).
**
** Reads the process environment (getenv and environ); the closed build has no other ENV. The environment is read,
** never written: the closed program's output depends on it only through what its script reads.
*/

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <stdlib.h>

extern char **environ;

static mrb_value
env_world_aref(mrb_state *mrb, mrb_value self)
{
  mrb_value key;
  mrb_get_args(mrb, "S", &key);
  const char *value = getenv(mrb_string_cstr(mrb, key));
  return value ? mrb_str_new_cstr(mrb, value) : mrb_nil_value();
}

static mrb_value
env_world_pairs(mrb_state *mrb, mrb_value self)
{
  mrb_value out = mrb_ary_new(mrb);
  for (char **e = environ; e && *e; e++) {
    mrb_ary_push(mrb, out, mrb_str_new_cstr(mrb, *e));
  }
  return out;
}

void
mrb_mruby_env_world_gem_init(mrb_state *mrb)
{
  struct RClass *c = mrb_define_class(mrb, "ENVClass", mrb->object_class);
  mrb_define_method(mrb, c, "[]", env_world_aref, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, c, "__environ_pairs", env_world_pairs, MRB_ARGS_NONE());
}

void
mrb_mruby_env_world_gem_final(mrb_state *mrb)
{
}
