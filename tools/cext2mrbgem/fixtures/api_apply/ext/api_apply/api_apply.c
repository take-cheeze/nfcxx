#include <ruby.h>
static VALUE mApply;
static VALUE apply_call(VALUE self, VALUE recv, VALUE args) {
    return rb_apply(recv, rb_intern("to_s"), args);
}
void Init_api_apply(void) {
    mApply = rb_define_module("Apply");
    rb_define_module_function(mApply, "call", apply_call, 2);
}
