#include <ruby.h>

static VALUE m_check(VALUE self, VALUE obj)
{
    if (T_STRUCT != rb_type(obj)) {
        rb_raise(rb_eArgError, "not a Struct");
    }
    if (T_STRUCT == rb_type(obj)) {
        return Qtrue;
    }
    return Qfalse;
}

void Init_api_struct_cmp(void)
{
    rb_define_method(rb_cObject, "check_struct", m_check, 1);
}
