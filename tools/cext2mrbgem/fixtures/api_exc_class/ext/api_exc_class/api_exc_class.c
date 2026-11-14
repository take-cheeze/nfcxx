#include <ruby.h>
static VALUE mExcClass;
static VALUE ec_check(VALUE self, VALUE v) {
    if (rb_obj_is_kind_of(v, rb_cNumeric)) return Qtrue;
    rb_raise(rb_eIOError, "bad");
}
void Init_api_exc_class(void) {
    mExcClass = rb_define_module("ExcClass");
    rb_define_module_function(mExcClass, "check", ec_check, 1);
}
