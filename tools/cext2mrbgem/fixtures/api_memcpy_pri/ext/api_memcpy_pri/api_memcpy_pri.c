#include <ruby.h>

static VALUE m_copy(VALUE self, VALUE str)
{
    char buf[8];
    long n = RSTRING_LEN(str);
    if (n > 8) n = 8;
    MEMCPY(buf, RSTRING_PTR(str), char, n);
    return rb_sprintf("%"PRIdVALUE" %"PRIuSIZE, n, (size_t)n);
}

void Init_api_memcpy_pri(void)
{
    rb_define_method(rb_cObject, "copy_pri", m_copy, 1);
}
