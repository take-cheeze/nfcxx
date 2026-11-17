#include <ruby.h>

static VALUE m_ctx(VALUE self, VALUE obj)
{
    void *ctx = (void *)obj;
    return ctx ? Qtrue : Qfalse;
}

void Init_api_value_ptr(void)
{
    VALUE holder = Qnil;
    rb_define_method(rb_cObject, "ctx", m_ctx, 1);
    (void)holder;
}
