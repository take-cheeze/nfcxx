#include <ruby.h>

/* rb_define_alias on a tracked class variable: the class is a struct RClass *, passed unwrapped (api_map.json, batch D5). */
static VALUE cApiAlias;

static VALUE api_orig(VALUE self) {
    return self;
}

void Init_api_alias(void) {
    cApiAlias = rb_define_class("ApiAlias", rb_cObject);
    rb_define_method(cApiAlias, "orig", api_orig, 0);
    rb_define_alias(cApiAlias, "copy", "orig");
}
