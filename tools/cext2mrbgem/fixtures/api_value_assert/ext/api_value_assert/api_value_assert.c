#include <ruby.h>
#include <assert.h>

static VALUE m_check(VALUE self, VALUE obj)
{
    assert(obj);
    return Qtrue;
}

void Init_api_value_assert(void)
{
    rb_define_method(rb_cObject, "check", m_check, 1);
}
