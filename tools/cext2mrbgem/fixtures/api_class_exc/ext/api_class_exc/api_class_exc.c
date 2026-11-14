#include <ruby.h>

/* Built-in class and exception references with an exact mruby equivalent (api_map.json, batch D1). */
static VALUE mApiClass;

static VALUE api_kind(VALUE self, VALUE obj) {
    if (rb_obj_is_kind_of(obj, rb_cHash)) return Qtrue;
    if (rb_obj_is_kind_of(obj, rb_cString)) return Qtrue;
    return Qfalse;
}

static VALUE api_fail(VALUE self, VALUE key) {
    rb_raise(rb_eKeyError, "missing key");
    return Qnil;
}

void Init_api_class_exc(void) {
    mApiClass = rb_define_module("ApiClass");
    rb_define_module_function(mApiClass, "kind", api_kind, 1);
    rb_define_module_function(mApiClass, "fail", api_fail, 1);
}
