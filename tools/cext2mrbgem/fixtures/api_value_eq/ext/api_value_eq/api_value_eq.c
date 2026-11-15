#include <ruby.h>
static VALUE mValueEq;
static VALUE veq_same(VALUE self, VALUE a, VALUE b) {
    return (a == b) ? Qtrue : Qfalse;
}
struct veq_box { VALUE v; };
static struct veq_box veq_state;
static VALUE veq_member(VALUE self, VALUE w) {
    return (veq_state.v == w) ? Qtrue : Qfalse;
}
void Init_api_value_eq(void) {
    mValueEq = rb_define_module("ValueEq");
    rb_define_module_function(mValueEq, "same", veq_same, 2);
    rb_define_module_function(mValueEq, "member", veq_member, 1);
}
