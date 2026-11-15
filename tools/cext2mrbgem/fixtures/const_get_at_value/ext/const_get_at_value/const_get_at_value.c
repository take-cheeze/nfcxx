#include <ruby.h>

/* the receiver is a VALUE parameter: a class value, unwrapped with mrb_class_ptr */
static VALUE cgv_lookup(VALUE self, VALUE mod) {
    ID version = rb_intern("VERSION");
    return rb_const_get_at(mod, version);
}

void Init_const_get_at_value(void) {
    VALUE m = rb_define_module("ConstGetAtValue");
    rb_define_module_function(m, "lookup", cgv_lookup, 1);
}
