#include <ruby.h>

/* a Rational test: CRuby's Rational class (the mruby-rational gem's class in the converted gem) */
static VALUE
m_is_rational(VALUE self, VALUE v)
{
    return RB_TYPE_P(v, T_RATIONAL) ? Qtrue : Qfalse;
}

void
Init_api_rational_gem(void)
{
    VALUE c = rb_define_class("RationalGem", rb_cObject);
    rb_define_method(c, "rational?", m_is_rational, 1);
}
