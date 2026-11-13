#include <ruby.h>

/* Class-name and method-undef calls with an exact mruby equivalent (api_map.json, batch C1). */
static VALUE mApiClass;
static VALUE cApiBase;

static VALUE api_class_name(VALUE self) {
    const char *name = rb_class2name(cApiBase);
    return rb_str_new_cstr(name);
}

static VALUE api_drop_to_s(VALUE self) {
    rb_undef_method(cApiBase, "to_s");
    return Qnil;
}

void Init_api_class_undef(void) {
    mApiClass = rb_define_module("ApiClass");
    cApiBase = rb_define_class_under(mApiClass, "Base", rb_cObject);
    rb_define_module_function(mApiClass, "name_of", api_class_name, 0);
    rb_define_module_function(mApiClass, "drop_to_s", api_drop_to_s, 0);
}
