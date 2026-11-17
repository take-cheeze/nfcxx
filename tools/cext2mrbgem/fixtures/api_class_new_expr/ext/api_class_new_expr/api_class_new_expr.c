#include <ruby.h>

static VALUE m_make(VALUE self, VALUE arr)
{
    VALUE obj = rb_class_new_instance((int)(RARRAY_LEN(arr) - 1), RARRAY_CONST_PTR(arr) + 1, rb_cRange);
    return obj;
}

void Init_api_class_new_expr(void)
{
    rb_define_method(rb_cObject, "make_range", m_make, 1);
}
