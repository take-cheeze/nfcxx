#include <ruby.h>
static VALUE mRa;

static VALUE ra_make(VALUE self, VALUE n) {
    return rb_rational_new2(rb_funcall(n, rb_intern("to_i"), 0), INT2FIX(3));
}

void Init_api_rational_args(void) {
    mRa = rb_define_module("RationalArgs");
    rb_define_module_function(mRa, "make", ra_make, 1);
}
