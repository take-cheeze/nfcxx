#include <ruby.h>
static VALUE mRaisePv;
static VALUE rp_check(VALUE self, VALUE v) {
    if (!RTEST(v)) rb_raise(rb_eArgError, "bad value %"PRIsVALUE" here", v);
    return v;
}
void Init_api_raise_pv(void) {
    mRaisePv = rb_define_module("RaisePv");
    rb_define_module_function(mRaisePv, "check", rp_check, 1);
}
