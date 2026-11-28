/* milestone 2 of the mruby compatibility layer: builtin methods on core values and program objects, through mrb_funcall and the
 * helpers. The program is point.rb (class Point with initialize, sum, @x and @y), lowered by bc2cpp --backend=mrbbc. */
#include <stdio.h>
#include <string.h>
#include "../mruby.h"

extern "C" void mrb_irep_0(MV *ret);

static mrb_state M;
static int failures = 0;

static void check(bool ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

static bool str_is(mrb_value v, const char *s) {
  return mrb_type(v) == MRB_TT_STRING && RSTRING_LEN(v) == (mrb_int)strlen(s) && memcmp(RSTRING_PTR(v), s, strlen(s)) == 0;
}

static void entry(MV *ret) {
  MV top;
  mrb_irep_0(&top);
  nfcx_state_init(&M);
  RClass *pt = mrb_class_get(&M, "Point");
  mrb_value obj = mrb_obj_value(mrb_obj_alloc(&M, MRB_TT_OBJECT, pt));
  mrb_funcall(&M, obj, "initialize", 2, mrb_fixnum_value(3), mrb_fixnum_value(4));

  /* instance_variables, then sort! on it (marshal sorts the ivar names it writes) */
  mrb_value ivs = mrb_funcall(&M, obj, "instance_variables", 0);
  check(mrb_fixnum(mrb_funcall(&M, ivs, "size", 0)) == 2, "instance_variables has two names");
  mrb_funcall(&M, ivs, "sort!", 0);
  check(mrb_symbol(mrb_ary_ref(&M, ivs, 0)) == mrb_intern_cstr(&M, "@x"), "sorted instance_variables starts with @x");

  /* respond_to? for a program method and for a missing one */
  check(mrb_test(mrb_funcall(&M, obj, "respond_to?", 1, mrb_symbol_value(mrb_intern_cstr(&M, "sum")))), "respond_to?(:sum) is true");
  check(!mrb_test(mrb_funcall(&M, obj, "respond_to?", 1, mrb_symbol_value(mrb_intern_cstr(&M, "nope")))), "respond_to?(:nope) is false");

  /* sort! on an array of symbols, and of integers */
  mrb_value syms = mrb_ary_new(&M);
  mrb_ary_push(&M, syms, mrb_symbol_value(mrb_intern_cstr(&M, "b")));
  mrb_ary_push(&M, syms, mrb_symbol_value(mrb_intern_cstr(&M, "a")));
  mrb_ary_push(&M, syms, mrb_symbol_value(mrb_intern_cstr(&M, "c")));
  mrb_funcall(&M, syms, "sort!", 0);
  check(mrb_symbol(mrb_ary_ref(&M, syms, 0)) == mrb_intern_cstr(&M, "a") && mrb_symbol(mrb_ary_ref(&M, syms, 2)) == mrb_intern_cstr(&M, "c"),
        "sort! orders symbols by name");
  mrb_value ints = mrb_ary_new(&M);
  mrb_ary_push(&M, ints, mrb_fixnum_value(10));
  mrb_ary_push(&M, ints, mrb_fixnum_value(-2));
  mrb_ary_push(&M, ints, mrb_fixnum_value(3));
  mrb_funcall(&M, ints, "sort!", 0);
  check(mrb_fixnum(mrb_ary_ref(&M, ints, 0)) == -2 && mrb_fixnum(mrb_ary_ref(&M, ints, 2)) == 10, "sort! orders integers");

  /* a hash: keys, and the value of a string key */
  mrb_value h = mrb_hash_new_capa(&M, 2);
  mrb_hash_set(&M, h, mrb_str_new(&M, "b", 1), mrb_fixnum_value(1));
  mrb_hash_set(&M, h, mrb_str_new(&M, "a", 1), mrb_fixnum_value(2));
  mrb_value keys = mrb_funcall(&M, h, "keys", 0);
  check(mrb_fixnum(mrb_funcall(&M, keys, "size", 0)) == 2, "Hash#keys has two keys");
  check(mrb_fixnum(mrb_hash_get(&M, h, mrb_str_new(&M, "a", 1))) == 2, "hash value of the key \"a\" is 2");
  check(mrb_fixnum(mrb_funcall(&M, h, "size", 0)) == 2, "Hash#size is 2");

  /* names and classes */
  check(str_is(mrb_class_path(&M, pt), "Point"), "mrb_class_path(Point) is \"Point\"");
  check(mrb_obj_is_kind_of(&M, obj, pt), "the object is a Point");
  check(str_is(mrb_funcall(&M, mrb_symbol_value(mrb_intern_cstr(&M, "abc")), "to_s", 0), "abc"), "Symbol#to_s");
  check(mrb_fixnum(mrb_funcall(&M, mrb_str_new(&M, "hello", 5), "size", 0)) == 5, "String#size");

  *ret = mrb_nil_value();
}

int main(int argc, char **argv) {
  MV ret = {0};
  (void)argc;
  mrbbc_progname = argv[0];
  mrbbc_run(entry, &ret);
  printf(failures ? "milestone 2 FAILED\n" : "milestone 2 OK\n");
  return failures ? 1 : 0;
}
