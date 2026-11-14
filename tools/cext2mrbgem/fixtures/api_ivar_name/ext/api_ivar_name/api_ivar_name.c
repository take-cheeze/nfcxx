#include <ruby.h>

/* Instance variables named by a string literal (api_map.json, batch D3): the name is interned at each call. */
static VALUE mApiIv;

static VALUE api_get(VALUE self, VALUE obj) {
    return rb_iv_get(obj, "@count");
}

static VALUE api_put(VALUE self, VALUE obj, VALUE v) {
    rb_iv_set(obj, "@count", v);
    return v;
}

void Init_api_ivar_name(void) {
    mApiIv = rb_define_module("ApiIv");
    rb_define_module_function(mApiIv, "get", api_get, 1);
    rb_define_module_function(mApiIv, "put", api_put, 2);
}
