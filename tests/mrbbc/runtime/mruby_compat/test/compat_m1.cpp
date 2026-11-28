/* milestone 1 of the mruby compatibility layer: program classes and objects through the mruby names. The program (point.rb,
 * lowered by bc2cpp --backend=mrbbc) defines class Point. This test runs the program's top level, then makes a Point with
 * mrb_obj_alloc, calls its methods with mrb_funcall and reads and writes its instance variables. */
#include <stdio.h>
#include "../mruby.h"

extern "C" void mrb_irep_0(MV *ret);

static mrb_state M;
static int failures = 0;

static void check(bool ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

static void entry(MV *ret) {
  RClass *pt;
  RObject *o;
  mrb_value obj, s, s2, x;
  MV top;
  mrb_irep_0(&top);
  nfcx_state_init(&M);
  pt = mrb_class_get(&M, "Point");
  o = mrb_obj_alloc(&M, MRB_TT_OBJECT, pt);
  obj = mrb_obj_value(o);
  check(mrb_type(obj) == MRB_TT_OBJECT, "mrb_obj_alloc makes an object");
  mrb_funcall(&M, obj, "initialize", 2, mrb_fixnum_value(3), mrb_fixnum_value(4));
  s = mrb_funcall(&M, obj, "sum", 0);
  check(mrb_fixnum(s) == 7, "Point#sum after initialize(3, 4) == 7");
  x = mrb_iv_get(&M, obj, mrb_intern_cstr(&M, "@x"));
  check(mrb_fixnum(x) == 3, "@x is 3 (mrb_iv_get)");
  mrb_iv_set(&M, obj, mrb_intern_cstr(&M, "@x"), mrb_fixnum_value(10));
  s2 = mrb_funcall(&M, obj, "sum", 0);
  check(mrb_fixnum(s2) == 14, "after mrb_iv_set(@x, 10), sum == 14");
  check(mrb_class(&M, obj) == pt, "mrb_class of the object is Point");
  mrb_set_nil_ret:
  *ret = mrb_nil_value();
}

int main(int argc, char **argv) {
  MV ret = {0};
  (void)argc;
  mrbbc_progname = argv[0];
  mrbbc_run(entry, &ret);
  printf(failures ? "milestone 1 FAILED\n" : "milestone 1 OK\n");
  return failures ? 1 : 0;
}
