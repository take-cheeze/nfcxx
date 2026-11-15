#include <ruby.h>
static VALUE mRtpn;

static VALUE rtpn_check(VALUE self, VALUE v) {
    if (RB_TYPE_P(v, T_NIL)) return Qtrue;
    if (RB_TYPE_P(v, T_FALSE)) return INT2FIX(0);
    return Qnil;
}

void Init_api_rb_type_p_nil(void) {
    mRtpn = rb_define_module("RbTypePNil");
    rb_define_module_function(mRtpn, "check", rtpn_check, 1);
}
