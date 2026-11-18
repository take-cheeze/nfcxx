#include <ruby.h>

/* a VALUE tested with ! (CRuby's ! tests the word; the fork's struct has no exact test): a stuck point */
static VALUE
m_not(VALUE self, VALUE v)
{
    if (!v) return Qtrue;
    return Qfalse;
}

/* DECIMAL_SIZE_OF_BITS(n) is CRuby's arithmetic for the decimal digits of n bits: mapped to its expression */
enum { DECIMAL_DIGITS = DECIMAL_SIZE_OF_BITS(64) };

/* a symbol VALUE passed to rb_id2name: the symbol is read with mrb_symbol */
static VALUE
m_name(VALUE self, VALUE sym)
{
    return rb_str_new_cstr(rb_id2name(sym));
}

void
Init_api_value_not_decimal(void)
{
    VALUE c = rb_define_class("ValueNotDecimal", rb_cObject);
    rb_define_method(c, "not_v", m_not, 1);
    rb_define_method(c, "name", m_name, 1);
    (void)DECIMAL_DIGITS;
}
