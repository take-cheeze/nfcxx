#include <ruby.h>

/* rb_const_get_at looks only in the receiver (the fork's mrb_const_get_at); the receiver is a tracked module */
static VALUE mCGA;

static VALUE cga_lookup(VALUE self) {
    ID version = rb_intern("VERSION");
    return rb_const_get_at(mCGA, version);
}

void Init_const_get_at(void) {
    mCGA = rb_define_module("ConstGetAt");
    rb_define_module_function(mCGA, "lookup", cga_lookup, 0);
}
