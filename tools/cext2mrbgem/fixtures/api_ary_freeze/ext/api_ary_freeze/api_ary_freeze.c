#include <ruby.h>
static VALUE mAf;

static VALUE af_freeze(VALUE self, VALUE ary) {
    rb_ary_freeze(ary);
    return ary;
}

void Init_api_ary_freeze(void) {
    mAf = rb_define_module("AryFreeze");
    rb_define_module_function(mAf, "freeze", af_freeze, 1);
}
