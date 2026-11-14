#include <ruby.h>

/* Global variables named by a string literal (api_map.json batch N6): the name is interned at each call. */
static VALUE mApiGv;

static VALUE api_get(VALUE self) {
    return rb_gv_get("$api_count");
}

static VALUE api_set(VALUE self, VALUE v) {
    rb_gv_set("$api_count", v);
    return v;
}

void Init_api_gv_name(void) {
    mApiGv = rb_define_module("ApiGv");
    rb_define_module_function(mApiGv, "get", api_get, 0);
    rb_define_module_function(mApiGv, "set", api_set, 1);
}
