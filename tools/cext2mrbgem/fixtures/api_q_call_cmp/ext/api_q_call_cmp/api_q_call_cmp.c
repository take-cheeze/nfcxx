#include <ruby.h>

/* an ID-typed variable that holds a symbol VALUE (assigned ID2SYM), used as a hash key */
static ID sym_key;

static VALUE
m_key(VALUE self, VALUE h)
{
    return rb_hash_aref(h, sym_key);
}

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
    sym_key = ID2SYM(rb_intern("key"));
    rb_define_method(c, "key", m_key, 1);
}
