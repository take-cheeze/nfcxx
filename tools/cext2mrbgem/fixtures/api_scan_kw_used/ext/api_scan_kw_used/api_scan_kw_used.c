#include <ruby.h>
static VALUE mSku;

static VALUE sku_count(int argc, VALUE *argv, VALUE self) {
    VALUE a, kw;
    int n = rb_scan_args(argc, argv, "1:", &a, &kw);
    return INT2FIX(n);
}

void Init_api_scan_kw_used(void) {
    mSku = rb_define_module("ScanKwUsed");
    rb_define_method(mSku, "count", sku_count, -1);
}
