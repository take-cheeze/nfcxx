#include <ruby.h>

/* a variadic macro: each expansion has its own count (the first argument) and values */
#define pair_of(...) rb_ary_new3(__VA_ARGS__)

static VALUE
m_table(VALUE self)
{
    return pair_of(2, self, INT2FIX(1));
}

void
Init_api_ary_new3_va(void)
{
    VALUE c = rb_define_class("AryNew3Va", rb_cObject);
    rb_define_method(c, "table", m_table, 0);
}
