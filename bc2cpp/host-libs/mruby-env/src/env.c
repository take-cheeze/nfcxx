/* The process environment, for mruby-env's ENV. Three primitives on the module BC2CPPEnv: get(name) -> String or nil,
 * set(name, value_or_nil), and pairs -> [[name, value], ...] in the environment's own order. */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <stdlib.h>

extern char **environ;

static mrb_value env_get(mrb_state *mrb, mrb_value self)
{
  const char *name;
  mrb_get_args(mrb, "z", &name);
  const char *value = getenv(name);
  return value ? mrb_str_new_cstr(mrb, value) : mrb_nil_value();
}

static mrb_value env_set(mrb_state *mrb, mrb_value self)
{
  const char *name;
  mrb_value value;
  mrb_get_args(mrb, "zo", &name, &value);
  if (mrb_nil_p(value)) {
    unsetenv(name);
  } else {
    mrb_value text = mrb_obj_as_string(mrb, value);
    setenv(name, RSTRING_PTR(text), 1);
  }
  return value;
}

static mrb_value env_pairs(mrb_state *mrb, mrb_value self)
{
  mrb_value out = mrb_ary_new(mrb);
  for (char **entry = environ; entry && *entry; entry++) {
    const char *eq = *entry;
    while (*eq && *eq != '=') eq++;
    if (*eq != '=') continue;
    mrb_value pair = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, pair, mrb_str_new(mrb, *entry, (mrb_int)(eq - *entry)));
    mrb_ary_push(mrb, pair, mrb_str_new_cstr(mrb, eq + 1));
    mrb_ary_push(mrb, out, pair);
  }
  return out;
}

void mrb_mruby_env_gem_init(mrb_state *mrb)
{
  struct RClass *prim = mrb_define_module(mrb, "BC2CPPEnv");
  mrb_define_module_function(mrb, prim, "get", env_get, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, prim, "set", env_set, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, prim, "pairs", env_pairs, MRB_ARGS_NONE());
}

void mrb_mruby_env_gem_final(mrb_state *mrb)
{
}
