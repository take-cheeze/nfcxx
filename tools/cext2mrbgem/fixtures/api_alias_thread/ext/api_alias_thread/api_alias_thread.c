#include <ruby.h>

static VALUE wrap_one(VALUE x)
{
    VALUE ary = rb_ary_new_capa(1);
    rb_ary_push(ary, x);
    return ary;
}

#define MakeOne wrap_one

static VALUE m_wrap(VALUE self, VALUE v)
{
    return MakeOne(v);
}

void Init_api_alias_thread(void)
{
    rb_define_method(rb_cObject, "wrap_one", m_wrap, 1);
}
