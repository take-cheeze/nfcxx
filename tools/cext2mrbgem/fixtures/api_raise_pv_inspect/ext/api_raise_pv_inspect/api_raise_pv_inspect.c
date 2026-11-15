#include <ruby.h>
static VALUE mRpi;
static VALUE rpi_check(VALUE self, VALUE v) {
    if (!RTEST(v)) rb_raise(rb_eArgError, "bad value %+"PRIsVALUE" here", v);
    return v;
}
void Init_api_raise_pv_inspect(void) {
    mRpi = rb_define_module("RaisePvInspect");
    rb_define_module_function(mRpi, "check", rpi_check, 1);
}
