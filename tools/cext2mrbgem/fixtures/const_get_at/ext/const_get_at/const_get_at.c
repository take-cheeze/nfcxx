#include <ruby.h>

/* rb_const_get_at looks only in the receiver: no exact mruby equivalent, so it stays refused. */
static VALUE mCGA;

static VALUE cga_lookup(VALUE self) {
    return rb_const_get_at(mCGA, rb_intern("VERSION"));
}

void Init_const_get_at(void) {
    mCGA = rb_define_module("ConstGetAt");
    rb_define_module_function(mCGA, "lookup", cga_lookup, 0);
}
