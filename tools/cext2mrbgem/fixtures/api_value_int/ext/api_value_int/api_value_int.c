#include <ruby.h>

/* a function whose parameter is an integer key (sid_t-like), not a VALUE */
static VALUE
lookup_key(unsigned long key)
{
    return key ? Qtrue : Qfalse;
}

/* a VALUE passed as that integer key: CRuby passes the VALUE's word, which the fork's VALUE struct has no integer form of */
static VALUE
m_by_obj(VALUE self, VALUE obj)
{
    return lookup_key(obj);
}

void
Init_api_value_int(void)
{
    VALUE c = rb_define_class("ValueInt", rb_cObject);
    rb_define_method(c, "by_obj", m_by_obj, 1);
}
