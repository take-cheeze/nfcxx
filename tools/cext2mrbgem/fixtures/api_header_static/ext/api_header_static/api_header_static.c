#include <ruby.h>
#include "helper.h"

static VALUE mHS;

static VALUE hs_run(VALUE self, VALUE v) {
    return INT2NUM(hs_check(v));
}

void Init_api_header_static(void) {
    mHS = rb_define_module("HeaderStatic");
    rb_define_module_function(mHS, "run", hs_run, 1);
}
