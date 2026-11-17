#include <ruby.h>

/* a number parsed from a C string, with badcheck; a value with a to_str conversion, or nil */
static VALUE
m_dbl(VALUE self, VALUE str)
{
    return DBL2NUM(rb_cstr_to_dbl(RSTRING_PTR(str), 1));
}

static VALUE
m_to_str(VALUE self, VALUE val)
{
    return rb_check_convert_type(val, T_STRING, "String", "to_str");
}

/* yields to the block, or raises LocalJumpError when there is none */
static VALUE
m_each_twice(VALUE self)
{
    rb_need_block();
    rb_yield(INT2FIX(1));
    return rb_yield(INT2FIX(2));
}

void
Init_api_conv_misc(void)
{
    VALUE c = rb_define_class("ConvMisc", rb_cObject);
    rb_define_method(c, "dbl", m_dbl, 1);
    rb_define_method(c, "to_str", m_to_str, 1);
    rb_define_method(c, "each_twice", m_each_twice, 0);
}
