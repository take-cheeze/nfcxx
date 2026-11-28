#include <ruby.h>

/* A protected registration (CRuby's rb_define_protected_method): the same wrapper and argument spec as rb_define_method. */
static VALUE cApiProt;

static VALUE api_guarded(VALUE self, VALUE x) {
    return x;
}

void Init_api_protected_reg(void) {
    cApiProt = rb_define_class("ApiProt", rb_cObject);
    rb_define_protected_method(cApiProt, "guarded", api_guarded, 1);
}
