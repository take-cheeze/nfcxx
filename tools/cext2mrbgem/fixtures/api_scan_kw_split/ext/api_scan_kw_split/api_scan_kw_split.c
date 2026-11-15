#include <ruby.h>
static VALUE mScanKw;
static VALUE sk_pick(int argc, VALUE *argv, VALUE self) {
    VALUE str, opt;
    argc = rb_scan_args(argc, argv, "1:", &str, &opt);
    return INT2FIX(argc);
}
static VALUE sk_call(VALUE self, VALUE a) {
    return sk_pick(1, &a, self);
}

void Init_api_scan_kw_split(void) {
    mScanKw = rb_define_module("ScanKw");
    rb_define_module_function(mScanKw, "pick", sk_pick, -1);
    rb_define_module_function(mScanKw, "call", sk_call, 1);
}
