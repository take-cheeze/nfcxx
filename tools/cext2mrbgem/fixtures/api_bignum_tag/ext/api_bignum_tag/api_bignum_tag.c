#include <ruby.h>

/* T_BIGNUM is the tag of a value outside the fixnum range: a type test and a Check_Type on it */
static VALUE
bt_big_p(VALUE self, VALUE v)
{
    return TYPE(v) == T_BIGNUM ? Qtrue : Qfalse;
}

static VALUE
bt_check(VALUE self, VALUE v)
{
    Check_Type(v, T_BIGNUM);
    return Qtrue;
}

void
Init_api_bignum_tag(void)
{
    VALUE m = rb_define_module("BigTag");
    rb_define_module_function(m, "big_p", bt_big_p, 1);
    rb_define_module_function(m, "check", bt_check, 1);
}
