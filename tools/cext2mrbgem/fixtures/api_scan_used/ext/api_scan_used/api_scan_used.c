#include <ruby.h>
static VALUE mSu;

static VALUE su_count(int argc, VALUE *argv, VALUE self) {
    VALUE a, b;
    int n = rb_scan_args(argc, argv, "11", &a, &b);
    return INT2FIX(n);
}

void Init_api_scan_used(void) {
    mSu = rb_define_module("ScanUsed");
    rb_define_method(mSu, "count", su_count, -1);
}
