#include <ruby.h>

/* rb_hash_foreach with a pointer passed as VALUE (api_map.json batch N11): the callback is threaded, its arg is void * */
typedef struct { int n; } counter;

static int count_cb(VALUE key, VALUE val, VALUE arg) {
    counter *c = (counter *)arg;
    c->n++;
    return ST_CONTINUE;
}

static VALUE mApiHf;

static VALUE api_count(VALUE self, VALUE h) {
    counter c = {0};
    rb_hash_foreach(h, count_cb, (VALUE)&c);
    return INT2NUM(c.n);
}

void Init_api_hash_foreach(void) {
    mApiHf = rb_define_module("ApiHf");
    rb_define_module_function(mApiHf, "count", api_count, 1);
}
