#include <ruby.h>

#ifndef MAYBE_UNUSED
# define MAYBE_UNUSED(x) x
#endif

MAYBE_UNUSED(static VALUE make_pair(int n));
#define NewPair make_pair

static VALUE
make_pair(int n)
{
    VALUE ary = rb_ary_new_capa(2);
    rb_ary_push(ary, INT2NUM(n));
    rb_ary_push(ary, INT2NUM(n + 1));
    return ary;
}

static VALUE m_pair(VALUE self, VALUE n)
{
    return NewPair(NUM2INT(n));
}

void Init_api_maybe_unused_proto(void)
{
    rb_define_method(rb_cObject, "pair", m_pair, 1);
}
