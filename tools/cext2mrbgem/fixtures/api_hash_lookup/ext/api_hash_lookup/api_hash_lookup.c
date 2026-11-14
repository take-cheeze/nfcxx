#include <ruby.h>

/* rb_hash_lookup(hash, key) (api_map.json batch N2): mrb_hash_fetch with a nil default */
static VALUE mApiHash;

static VALUE api_get(VALUE self, VALUE h, VALUE k) {
    return rb_hash_lookup(h, k);
}

void Init_api_hash_lookup(void) {
    mApiHash = rb_define_module("ApiHash");
    rb_define_module_function(mApiHash, "get", api_get, 2);
}
