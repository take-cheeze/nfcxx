#include <ruby.h>

/* rb_sym2str(sym) (api_map.json batch N3): the Symbol VALUE is converted with mrb_symbol for mrb_sym_str */
static VALUE mApiSym;

static VALUE api_name(VALUE self, VALUE sym) {
    return rb_sym2str(sym);
}

void Init_api_sym_str(void) {
    mApiSym = rb_define_module("ApiSym");
    rb_define_module_function(mApiSym, "name", api_name, 1);
}
