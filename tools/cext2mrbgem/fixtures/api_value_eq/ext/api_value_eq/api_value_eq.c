#include <ruby.h>
static VALUE mValueEq;
static VALUE veq_same(VALUE self, VALUE a, VALUE b) {
    return (a == b) ? Qtrue : Qfalse;
}
void Init_api_value_eq(void) {
    mValueEq = rb_define_module("ValueEq");
    rb_define_module_function(mValueEq, "same", veq_same, 2);
}
