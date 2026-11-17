#include <ruby.h>

/* a call compared with nil and false: identity in CRuby, a test of the value in mruby (the call is evaluated once) */
static VALUE
m_missing(VALUE self, VALUE h, VALUE k)
{
    if (rb_hash_aref(h, k) == Qnil) return Qtrue;
    if (rb_hash_aref(h, k) != Qfalse) return Qfalse;
    return Qnil;
}

void
Init_api_q_call_cmp(void)
{
    VALUE c = rb_define_class("QCallCmp", rb_cObject);
    rb_define_method(c, "missing", m_missing, 2);
}
