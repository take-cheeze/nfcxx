#include <ruby.h>
static VALUE mTr;

static VALUE tr_is_rational(VALUE self, VALUE v) {
    return RB_TYPE_P(v, T_RATIONAL) ? Qtrue : Qfalse;
}

void Init_api_rb_type_rational(void) {
    mTr = rb_define_module("TypeRational");
    rb_define_module_function(mTr, "rational?", tr_is_rational, 1);
}
