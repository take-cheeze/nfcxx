#include <ruby.h>
static VALUE mEs;

/* no method calls it with state: a comparison in a function without the mruby state */
static VALUE es_same(VALUE a, VALUE b) {
    return a == b ? Qtrue : Qfalse;
}

static VALUE es_check(VALUE self, VALUE a, VALUE b) {
    return es_same(a, b);
}

void Init_api_eq_stateless(void) {
    mEs = rb_define_module("EqStateless");
    rb_define_module_function(mEs, "same", es_check, 2);
}
