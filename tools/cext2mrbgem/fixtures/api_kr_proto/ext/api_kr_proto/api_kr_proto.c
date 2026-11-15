#include <ruby.h>

static VALUE kp_helper _((VALUE x));
static VALUE kp_run _((VALUE self, VALUE v));

static VALUE kp_helper(VALUE x) {
    return rb_str_new_cstr("h");
}

static VALUE kp_run(VALUE self, VALUE v) {
    return kp_helper(v);
}

void Init_api_kr_proto(void) {
    VALUE m = rb_define_module("KrProto");
    rb_define_module_function(m, "run", kp_run, 1);
}
