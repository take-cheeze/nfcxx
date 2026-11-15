#include <ruby.h>
static VALUE mCi;

static VALUE ci_error(VALUE self) {
    return rb_const_get_at(rb_cObject, rb_intern("Comparable"));
}

void Init_api_const_intern(void) {
    mCi = rb_define_module("ConstIntern");
    rb_define_module_function(mCi, "error", ci_error, 0);
}
