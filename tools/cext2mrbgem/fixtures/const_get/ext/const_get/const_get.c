#include <ruby.h>

/* rb_const_get on a tracked module, on rb_cObject and on a VALUE parameter. */
static VALUE mCG;

static VALUE cg_lookup(VALUE self) {
    ID id = rb_intern("VERSION");
    return rb_const_get(mCG, id);
}

static VALUE cg_object(VALUE self) {
    return rb_const_get(rb_cObject, rb_intern("String"));
}

static VALUE cg_param(VALUE self, VALUE klass) {
    return rb_const_get(klass, rb_intern("Foo"));
}

void Init_const_get(void) {
    mCG = rb_define_module("ConstGet");
    rb_define_const(mCG, "VERSION", INT2FIX(1));
    rb_define_module_function(mCG, "lookup", cg_lookup, 0);
    rb_define_module_function(mCG, "object", cg_object, 0);
    rb_define_module_function(mCG, "param", cg_param, 1);
}
