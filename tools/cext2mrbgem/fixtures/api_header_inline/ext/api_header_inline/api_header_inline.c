#include <ruby.h>
#include "helper.h"

static VALUE m;

static VALUE ahi_run(VALUE self, VALUE v) {
    return INT2NUM(ahi_check(v));
}

void Init_api_header_inline(void) {
    m = rb_define_module("AHI");
    rb_define_module_function(m, "run", ahi_run, 1);
}
