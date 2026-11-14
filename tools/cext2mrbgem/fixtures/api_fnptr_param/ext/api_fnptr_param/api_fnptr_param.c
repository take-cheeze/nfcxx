#include <ruby.h>
static VALUE mFnptrParam;
static VALUE fp_cb(VALUE v, VALUE hash) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return hash;
}
static VALUE fp_each(VALUE (*cb)(VALUE, VALUE), VALUE v, VALUE hash) {
    return cb(v, hash);
}
static VALUE fp_run(VALUE self, VALUE v) {
    return fp_each(fp_cb, v, Qnil);
}
void Init_api_fnptr_param(void) {
    mFnptrParam = rb_define_module("FnptrParam");
    rb_define_module_function(mFnptrParam, "run", fp_run, 1);
}
