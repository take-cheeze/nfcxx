#include <ruby.h>

/* String, Hash and Array calls with an exact mruby equivalent (api_map.json, batch B1). */
static VALUE mApiMap;

static VALUE api_str(VALUE self, VALUE s) {
    VALUE dup = rb_str_dup(s);
    rb_str_cat(dup, "!", 1);
    rb_str_buf_new(16);
    rb_check_frozen(s);
    rb_obj_freeze(dup);
    return rb_str_intern(dup);
}

static VALUE api_hash(VALUE self, VALUE h, VALUE k) {
    VALUE fresh = rb_hash_new_capa(8);
    long n = RHASH_SIZE(h);
    rb_hash_delete(h, k);
    return fresh;
}

static VALUE api_ary(VALUE self, VALUE a) {
    VALUE copy = rb_ary_dup(a);
    VALUE fresh = rb_ary_new_capa(4);
    VALUE old = rb_ary_new2(2);
    rb_ary_store(copy, 0, fresh);
    rb_ary_clear(old);
    return rb_utf8_str_new_cstr("ok");
}

void Init_api_str_hash_ary(void) {
    mApiMap = rb_define_module("ApiMap");
    rb_define_module_function(mApiMap, "str", api_str, 1);
    rb_define_module_function(mApiMap, "hash_del", api_hash, 2);
    rb_define_module_function(mApiMap, "ary", api_ary, 1);
}
