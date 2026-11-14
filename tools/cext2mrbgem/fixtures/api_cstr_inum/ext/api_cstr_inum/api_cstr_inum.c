#include <ruby.h>

/* rb_cstr_to_inum(str, base, badcheck) (api_map.json batch N5): the C string becomes a String first */
static VALUE mApiInum;

static VALUE api_parse(VALUE self) {
    return rb_cstr_to_inum("12", 10, 0);
}

void Init_api_cstr_inum(void) {
    mApiInum = rb_define_module("ApiInum");
    rb_define_module_function(mApiInum, "parse", api_parse, 0);
}
