#include <ruby.h>

/* A private registration (api_map.json, batch D2): the same wrapper and argument spec as rb_define_method. */
static VALUE cApiPriv;

static VALUE api_secret(VALUE self, VALUE x) {
    return x;
}

void Init_api_private_reg(void) {
    cApiPriv = rb_define_class("ApiPriv", rb_cObject);
    rb_define_private_method(cApiPriv, "secret", api_secret, 1);
}
