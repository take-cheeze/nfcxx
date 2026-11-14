#include <ruby.h>
static VALUE mKv;

static VALUE kv_is(VALUE self, VALUE x, VALUE c) {
    return rb_obj_is_kind_of(x, c);
}

void Init_api_kind_value(void) {
    mKv = rb_define_module("KindValue");
    rb_define_module_function(mKv, "is", kv_is, 2);
}
