#include <ruby.h>
static VALUE ct_digit(VALUE self, VALUE c) { return rb_isdigit(NUM2INT(c)) ? Qtrue : Qfalse; }
void Init_api_ctype(void) { VALUE m = rb_define_module("CType"); rb_define_module_function(m, "digit", ct_digit, 1); }
