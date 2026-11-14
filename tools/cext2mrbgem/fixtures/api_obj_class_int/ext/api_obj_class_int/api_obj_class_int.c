#include <ruby.h>

/* rb_obj_is_kind_of, rb_obj_id, CLASS_OF, rb_class_of, rb_include_module, rb_eFrozenError and RB_INTEGER_TYPE_P
 * (api_map.json, batch B1). cApiKind and mApiMix are class variables: passed unwrapped where the position is
 * listed in special_arg_positions_class_only. */
static VALUE mApiObj;
static VALUE cApiKind;
static VALUE mApiMix;

static VALUE api_kind(VALUE self, VALUE obj) {
    return rb_obj_is_kind_of(obj, cApiKind);
}

static VALUE api_id(VALUE self, VALUE obj) {
    return rb_obj_id(obj);
}

static VALUE api_class(VALUE self, VALUE obj) {
    VALUE k = rb_class_of(obj);
    (void)CLASS_OF(obj);
    return k;
}

static VALUE api_mix(VALUE self) {
    rb_include_module(cApiKind, mApiMix);
    return Qnil;
}

static VALUE api_int(VALUE self, VALUE v) {
    if (RB_INTEGER_TYPE_P(v)) return Qtrue;
    rb_raise(rb_eFrozenError, "not an integer");
    return Qfalse;
}

void Init_api_obj_class_int(void) {
    mApiObj = rb_define_module("ApiObj");
    cApiKind = rb_define_class("ApiKind", rb_cObject);
    mApiMix = rb_define_module("ApiMix");
    rb_define_module_function(mApiObj, "kind", api_kind, 1);
    rb_define_module_function(mApiObj, "id", api_id, 1);
    rb_define_module_function(mApiObj, "klass", api_class, 1);
    rb_define_module_function(mApiObj, "mix", api_mix, 0);
    rb_define_module_function(mApiObj, "int", api_int, 1);
}
