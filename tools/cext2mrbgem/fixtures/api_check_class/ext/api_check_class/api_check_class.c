#include <ruby.h>
static VALUE mCc;

static VALUE cc_check(VALUE self, VALUE v) {
    Check_Type(v, T_CLASS);
    return v;
}

void Init_api_check_class(void) {
    mCc = rb_define_module("CheckClass");
    rb_define_module_function(mCc, "check", cc_check, 1);
}
