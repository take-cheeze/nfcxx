#include <ruby.h>
static VALUE mDs;

static VALUE ds_inner(int argc, VALUE *argv, VALUE self) {
    VALUE a;
    rb_scan_args(argc, argv, "01", &a);
    return a == Qnil ? self : a;
}

static VALUE ds_outer(VALUE self) {
    return ds_inner(0, (VALUE *)NULL, self);
}

void Init_api_direct_scan(void) {
    mDs = rb_define_module("DirectScan");
    rb_define_module_function(mDs, "inner", ds_inner, -1);
    rb_define_module_function(mDs, "outer", ds_outer, 0);
}
