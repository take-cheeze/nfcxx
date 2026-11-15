#include <ruby.h>
static VALUE mScanHelper;
static VALUE sh_inner(int argc, VALUE *argv, VALUE self) {
    VALUE a, b;
    rb_scan_args(argc, argv, "11", &a, &b);
    return NIL_P(b) ? a : b;
}
static VALUE sh_outer(int argc, VALUE *argv, VALUE self) {
    return sh_inner(argc, argv, self);
}
void Init_api_scan_helper(void) {
    mScanHelper = rb_define_module("ScanHelper");
    rb_define_module_function(mScanHelper, "pick", sh_outer, -1);
}
