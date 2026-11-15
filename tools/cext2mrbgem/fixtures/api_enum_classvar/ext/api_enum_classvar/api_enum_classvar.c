#include <ruby.h>

static VALUE cK;

/* with no block the method returns its enumerator (RETURN_ENUMERATOR) */
static VALUE
m_each_n(int argc, VALUE *argv, VALUE self)
{
    RETURN_ENUMERATOR(self, argc, argv);
    rb_yield(self);
    return self;
}

/* a class variable is an argument of CLASS_OF and rb_singleton_class */
static VALUE
m_klass(VALUE self)
{
    return CLASS_OF(cK);
}

static VALUE
m_meta(VALUE self)
{
    return rb_singleton_class(cK);
}

void
Init_api_enum_classvar(void)
{
    cK = rb_define_class("EnumK", rb_cObject);
    rb_define_method(cK, "each_n", m_each_n, -1);
    rb_define_method(cK, "klass", m_klass, 0);
    rb_define_method(cK, "meta", m_meta, 0);
}
