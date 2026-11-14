#include <ruby.h>

/* A non-static callback is not converted: another file may call it with a VALUE argument (api_map.json batch N11) */
int shared_cb(VALUE key, VALUE val, VALUE arg) {
    return ST_CONTINUE;
}

static VALUE api_walk(VALUE self, VALUE h) {
    int dummy = 0;
    rb_hash_foreach(h, shared_cb, (VALUE)&dummy);
    return Qnil;
}

void Init_api_hash_foreach_refused(void) {
    VALUE m = rb_define_module("ApiHfr");
    rb_define_module_function(m, "walk", api_walk, 1);
}
