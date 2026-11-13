#include <ruby.h>

/* String, Array and Hash helpers with an exact mruby equivalent, and RFLOAT_VALUE (api_map.json, batch D3). */
static VALUE mApiOps;

static VALUE api_freeze(VALUE self, VALUE str) {
    return rb_str_freeze(str);
}

static VALUE api_append(VALUE self, VALUE dst, VALUE src) {
    rb_str_append(dst, src);
    return rb_str_resize(dst, 4);
}

static VALUE api_pair(VALUE self, VALUE a, VALUE b) {
    VALUE pair = rb_assoc_new(a, b);
    VALUE copy = rb_hash_dup(a);
    long n = rb_array_len(pair);
    double f = RFLOAT_VALUE(b);
    return n > 0 && f > 0.0 ? copy : pair;
}

void Init_api_str_ops(void) {
    mApiOps = rb_define_module("ApiOps");
    rb_define_module_function(mApiOps, "freeze", api_freeze, 1);
    rb_define_module_function(mApiOps, "append", api_append, 2);
    rb_define_module_function(mApiOps, "pair", api_pair, 2);
}
