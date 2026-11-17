#include <ruby.h>

static VALUE m_is_struct(VALUE self, VALUE obj)
{
    if (RB_TYPE_P(obj, T_STRUCT)) return Qtrue;
    return Qfalse;
}

void Init_api_struct_type(void)
{
    rb_define_method(rb_cObject, "struct_like", m_is_struct, 1);
}
