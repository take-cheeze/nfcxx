#include <ruby.h>

/* the coercion protocol: the other operand's coerce gives the pair the operation is applied to */
#define ADD_COERCED(x, y) rb_num_coerce_bin(x, y, '+')

static VALUE
m_add(VALUE self, VALUE other)
{
    return ADD_COERCED(self, other);
}

static VALUE
m_cmp(VALUE self, VALUE other)
{
    return rb_num_coerce_cmp(self, other, rb_intern("<=>"));
}

/* the :exception option of an options hash (CRuby's rb_opts_exception_p) */
static VALUE
m_opts(VALUE self, VALUE opts)
{
    return rb_opts_exception_p(opts, 1) ? Qtrue : Qfalse;
}

void
Init_api_coerce(void)
{
    VALUE c = rb_define_class("CoerceNum", rb_cObject);
    rb_define_method(c, "add", m_add, 1);
    rb_define_method(c, "cmp", m_cmp, 1);
    rb_define_method(c, "opts", m_opts, 1);
}
