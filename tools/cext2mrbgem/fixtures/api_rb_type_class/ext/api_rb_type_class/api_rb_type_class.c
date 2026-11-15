#include <ruby.h>
static VALUE mTc;

static VALUE tc_is_class(VALUE self, VALUE v) {
    return RB_TYPE_P(v, T_CLASS) ? Qtrue : Qfalse;
}

static VALUE tc_is_module(VALUE self, VALUE v) {
    return RB_TYPE_P(v, T_MODULE) ? Qtrue : Qfalse;
}

void Init_api_rb_type_class(void) {
    mTc = rb_define_module("TypeClass");
    rb_define_module_function(mTc, "class?", tc_is_class, 1);
    rb_define_module_function(mTc, "module?", tc_is_module, 1);
}
