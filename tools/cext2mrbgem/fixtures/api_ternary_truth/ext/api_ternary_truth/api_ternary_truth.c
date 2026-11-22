#include <ruby.h>

/* A VALUE funcall as the condition of ?: (CRuby tests the word; a boolean result is mrb_test). */
static VALUE
tt_ge(VALUE self, VALUE x)
{
    return rb_funcall(x, rb_intern(">="), 1, INT2FIX(69));
}

static VALUE
tt_cent(VALUE self, VALUE n)
{
    int c = tt_ge(self, n) ? 19 : 20;
    return INT2FIX(c);
}

void
Init_api_ternary_truth(void)
{
    VALUE m = rb_define_module("TernaryTruth");
    rb_define_module_function(m, "cent", tt_cent, 1);
}
