#include <ruby.h>
static VALUE mI3;

static VALUE i3_sym(VALUE self, VALUE v, VALUE n) {
    return ID2SYM(rb_intern3(RSTRING_PTR(v) + 1, NUM2LONG(n) + 1, rb_utf8_encoding()));
}

void Init_api_intern3(void) {
    mI3 = rb_define_module("Intern3");
    rb_define_module_function(mI3, "sym", i3_sym, 2);
}
