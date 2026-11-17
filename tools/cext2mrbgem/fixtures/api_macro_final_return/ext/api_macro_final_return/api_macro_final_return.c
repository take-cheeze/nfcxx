#include <ruby.h>

/* a macro whose last statement returns: the registered methods that expand it return the value (the macro restores the state) */
static VALUE make_pair(VALUE a, VALUE b) { return rb_ary_new3(2, a, b); }

#define PAIR_OR(a, b)                    \
    VALUE pair_tmp = make_pair((a), (b)); \
    return pair_tmp;

static VALUE m_pair(VALUE self, VALUE a, VALUE b)
{
    PAIR_OR(a, b)
}

void
Init_api_macro_final_return(void)
{
    VALUE c = rb_define_class("MacroFinalReturn", rb_cObject);
    rb_define_method(c, "pair", m_pair, 2);
}
