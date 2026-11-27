#include <ruby.h>

/* A decorator (json's NOINLINE, no #define in this file) in front of a definition that is not static: the function is an
 * ordinary external definition, and the decorator is dropped with its attribute and inline. */
NOINLINE(VALUE ext_shout(VALUE self, VALUE str))
{
    return rb_str_dup(str);
}

ALWAYS_INLINE(static) VALUE
ext_helper(VALUE str)
{
    return rb_str_dup(str);
}

static VALUE
ext_dup(VALUE self, VALUE str)
{
    return ext_helper(str);
}

void
Init_decorated_extern(void)
{
    VALUE mExt = rb_define_module("DecoratedExtern");
    rb_define_method(mExt, "shout", ext_shout, 1);
    rb_define_method(mExt, "dup_str", ext_dup, 1);
}
