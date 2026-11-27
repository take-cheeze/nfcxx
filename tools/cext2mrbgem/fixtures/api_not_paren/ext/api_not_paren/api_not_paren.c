#include <ruby.h>

/* a parenthesized operand of ! is a condition: the Boolean test of rb_obj_is_kind_of, not a VALUE negated */
static VALUE cls;

static VALUE not_kind(VALUE self, VALUE obj) {
  if (!(rb_obj_is_kind_of(obj, cls))) return Qfalse;
  return Qtrue;
}

void Init_api_not_paren(void) {
  cls = rb_cObject;
  rb_define_global_function("not_kind", not_kind, 1);
}
