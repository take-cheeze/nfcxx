#include <ruby.h>
static VALUE big_p(VALUE self, VALUE v) { return TYPE(v) == T_BIGNUM ? Qtrue : Qfalse; }
void Init_api_bignum_stuck(void) { VALUE m = rb_define_module("BigStuck"); rb_define_module_function(m, "big_p", big_p, 1); }
