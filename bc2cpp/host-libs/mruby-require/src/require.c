/*
 * require for the features the build provides (see include/mruby/require.h). The loaded features are the array
 * $LOADED_FEATURES; a feature is found there by its name.
 */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/require.h>
#include <mruby/compile.h>
#include <mruby/error.h>
#include <string.h>
#ifndef MRB_NO_STDIO
#include <stdio.h>
#endif

static mrb_value
loaded_features(mrb_state *mrb)
{
  mrb_sym sym = mrb_intern_lit(mrb, "$LOADED_FEATURES");
  mrb_value list = mrb_gv_get(mrb, sym);
  if (mrb_type(list) != MRB_TT_ARRAY) {
    list = mrb_ary_new(mrb);
    mrb_gv_set(mrb, sym, list);
  }
  return list;
}

static int
is_loaded(mrb_state *mrb, mrb_value list, const char *name)
{
  mrb_int i, n = RARRAY_LEN(list);
  size_t len = strlen(name);
  for (i = 0; i < n; i++) {
    mrb_value e = mrb_ary_ref(mrb, list, i);
    if (mrb_string_p(e) && (size_t)RSTRING_LEN(e) == len && memcmp(RSTRING_PTR(e), name, len) == 0) {
      return 1;
    }
  }
  return 0;
}

MRB_API void
mrb_require_provide(mrb_state *mrb, const char *name)
{
  mrb_value list = loaded_features(mrb);
  if (!is_loaded(mrb, list, name)) {
    mrb_ary_push(mrb, list, mrb_str_new_cstr(mrb, name));
  }
}

#ifndef MRB_NO_STDIO
/* The file a name loads: a name that starts with '/', './' or '../' is itself; any other is searched in $LOAD_PATH.
   A name without a .rb extension gets one. Returns a new string, or nil when no file is found. */
static mrb_value
resolve_path(mrb_state *mrb, const char *name)
{
  size_t len = strlen(name);
  int has_rb = len >= 3 && strcmp(name + len - 3, ".rb") == 0;
  char *file = NULL;
  int direct = name[0] == '/' || strncmp(name, "./", 2) == 0 || strncmp(name, "../", 3) == 0;

  if (direct) {
    FILE *f;
    file = mrb_malloc(mrb, len + 4);
    strcpy(file, name);
    if (!has_rb) strcat(file, ".rb");
    f = fopen(file, "r");
    if (f) {
      fclose(f);
      mrb_value out = mrb_str_new_cstr(mrb, file);
      mrb_free(mrb, file);
      return out;
    }
    mrb_free(mrb, file);
    return mrb_nil_value();
  }

  {
    mrb_value dirs = mrb_gv_get(mrb, mrb_intern_lit(mrb, "$LOAD_PATH"));
    mrb_int i, n;
    if (mrb_type(dirs) != MRB_TT_ARRAY) return mrb_nil_value();
    n = RARRAY_LEN(dirs);
    for (i = 0; i < n; i++) {
      mrb_value dir = mrb_ary_ref(mrb, dirs, i);
      FILE *f;
      size_t dlen;
      if (!mrb_string_p(dir)) continue;
      dlen = (size_t)RSTRING_LEN(dir);
      file = mrb_malloc(mrb, dlen + len + 6);
      memcpy(file, RSTRING_PTR(dir), dlen);
      file[dlen] = '/';
      strcpy(file + dlen + 1, name);
      if (!has_rb) strcat(file, ".rb");
      f = fopen(file, "r");
      if (f) {
        fclose(f);
        mrb_value out = mrb_str_new_cstr(mrb, file);
        mrb_free(mrb, file);
        return out;
      }
      mrb_free(mrb, file);
    }
  }
  return mrb_nil_value();
}

struct load_arg {
  FILE *f;
};

static mrb_value
load_body(mrb_state *mrb, void *userdata)
{
  struct load_arg *a = (struct load_arg *)userdata;
  return mrb_load_file(mrb, a->f);
}
#endif

MRB_API mrb_value
rb_require(mrb_state *mrb, const char *name)
{
  mrb_value list = loaded_features(mrb);
  if (is_loaded(mrb, list, name)) {
    return mrb_false_value();
  }
#ifndef MRB_NO_STDIO
  {
    mrb_value path = resolve_path(mrb, name);
    if (!mrb_nil_p(path)) {
      const char *p = RSTRING_PTR(path);
      mrb_bool err = FALSE;
      mrb_value r;
      struct load_arg arg;
      if (is_loaded(mrb, list, p)) {
        return mrb_false_value();
      }
      /* Recorded before the file runs, so a file that requires itself returns false instead of recursing. */
      mrb_ary_push(mrb, list, path);
      arg.f = fopen(p, "r");
      if (!arg.f) {
        mrb_ary_pop(mrb, list);
        mrb_raisef(mrb, mrb_class_get(mrb, "LoadError"), "cannot load such file -- %s", name);
      }
      r = mrb_protect_error(mrb, load_body, &arg, &err);
      fclose(arg.f);
      if (err) {
        mrb_ary_pop(mrb, list);
        mrb_exc_raise(mrb, r);
      }
      return mrb_true_value();
    }
  }
#endif
  mrb_raisef(mrb, mrb_class_get(mrb, "LoadError"), "cannot load such file -- %s", name);
  return mrb_nil_value();
}

/* The native half of require: built features (the loaded-feature list) and files. The Ruby side (mrblib/require.rb)
   answers the baked sources and the features its checks provide, and calls this (super) for anything else. */
static mrb_value
k_require(mrb_state *mrb, mrb_value self)
{
  mrb_value name;
  mrb_get_args(mrb, "S", &name);
  return rb_require(mrb, mrb_string_cstr(mrb, name));
}

/* Module#autoload(name, path): the constant is required from path when it is first looked up (see const_get). */
static mrb_value
mod_autoload(mrb_state *mrb, mrb_value self)
{
  mrb_value name, path, tbl;
  mrb_sym sym;

  mrb_get_args(mrb, "oS", &name, &path);
  sym = mrb_obj_to_sym(mrb, name);
  tbl = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "__autoload__"));
  if (!mrb_hash_p(tbl)) {
    tbl = mrb_hash_new(mrb);
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "__autoload__"), tbl);
  }
  mrb_hash_set(mrb, tbl, mrb_symbol_value(sym), path);
  return mrb_nil_value();
}

/* Module#autoload?(name): the path the constant autoloads from, or nil. */
static mrb_value
mod_autoload_p(mrb_state *mrb, mrb_value self)
{
  mrb_value name, tbl;
  mrb_sym sym;

  mrb_get_args(mrb, "o", &name);
  sym = mrb_obj_to_sym(mrb, name);
  tbl = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "__autoload__"));
  if (!mrb_hash_p(tbl)) return mrb_nil_value();
  return mrb_hash_get(mrb, tbl, mrb_symbol_value(sym));
}

void
mrb_mruby_require_gem_init(mrb_state *mrb)
{
  /* CRuby's ScriptError family. mruby's core has neither; the Ruby side defines them only if missing. */
  struct RClass *script;
  if (!mrb_class_defined(mrb, "ScriptError")) {
    mrb_define_class(mrb, "ScriptError", mrb_class_get(mrb, "StandardError"));
  }
  script = mrb_class_get(mrb, "ScriptError");
  if (!mrb_class_defined(mrb, "LoadError")) {
    mrb_define_class(mrb, "LoadError", script);
  }
  mrb_define_method(mrb, mrb->kernel_module, "require", k_require, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, mrb->module_class, "autoload", mod_autoload, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, mrb->module_class, "autoload?", mod_autoload_p, MRB_ARGS_REQ(1));
}

void
mrb_mruby_require_gem_final(mrb_state *mrb)
{
}
