#include <ruby.h>
static VALUE mSk;

static VALUE sk_run(int argc, VALUE *argv, VALUE self) {
    VALUE a, b, kw;
    rb_scan_args(argc, argv, "11:", &a, &b, &kw);
    return a;
}

void Init_api_scan_kw(void) {
    mSk = rb_define_module("ScanKw");
    rb_define_method(mSk, "run", sk_run, -1);
}
