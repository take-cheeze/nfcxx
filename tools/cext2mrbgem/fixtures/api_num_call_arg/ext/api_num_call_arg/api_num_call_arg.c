#include <ruby.h>
static VALUE mNca;

static VALUE nca_sec(VALUE self, VALUE obj) {
    long long sec = NUM2LL(rb_funcall2(obj, rb_intern("tv_sec"), 0, 0));
    return LL2NUM(sec);
}

void Init_api_num_call_arg(void) {
    mNca = rb_define_module("NumCallArg");
    rb_define_module_function(mNca, "sec", nca_sec, 1);
}
