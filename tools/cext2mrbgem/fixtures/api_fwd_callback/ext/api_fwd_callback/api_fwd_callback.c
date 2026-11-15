#include <ruby.h>
static VALUE mFwdCallback;
static VALUE fwd_c(VALUE v) { return rb_str_new_cstr("x"); }
static VALUE fwd_inner(VALUE v, VALUE (*c)(VALUE)) { return (*c)(v); }
static VALUE fwd_outer(VALUE v, VALUE (*c)(VALUE)) { return fwd_inner(v, c); }
static VALUE fwd_run(VALUE self, VALUE v) { return fwd_outer(v, fwd_c); }
void Init_api_fwd_callback(void) {
    mFwdCallback = rb_define_module("FwdCallback");
    rb_define_module_function(mFwdCallback, "run", fwd_run, 1);
}
