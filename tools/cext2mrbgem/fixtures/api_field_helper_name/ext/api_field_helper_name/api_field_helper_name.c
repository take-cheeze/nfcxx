#include <ruby.h>

/* A struct member with the same name as a helper: the member is a field, not a use of the helper. */
struct ops {
    VALUE (*sec)(VALUE f);
};
struct ops *cur_ops;

#define OP_SEC(x) (cur_ops->x)

static VALUE
sec(VALUE f)
{
    return rb_str_dup(f);
}

static VALUE
m_sec(VALUE self, VALUE f)
{
    return sec(f);
}

static VALUE
m_via_field(VALUE self, VALUE f)
{
    return OP_SEC(sec)(f);
}

void
Init_api_field_helper_name(void)
{
    VALUE c = rb_define_class("FieldHelper", rb_cObject);
    rb_define_method(c, "sec", m_sec, 1);
    rb_define_method(c, "via_field", m_via_field, 1);
}
