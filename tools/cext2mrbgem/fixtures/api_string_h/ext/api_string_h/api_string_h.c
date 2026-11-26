#include <ruby.h>

/* memcpy comes with CRuby's ruby.h (ruby.h includes <string.h>): the converted source must include it too */
static VALUE
m_copy(VALUE self, VALUE src)
{
    char buf[8];
    memcpy(buf, RSTRING_PTR(src), sizeof(buf) < (size_t)RSTRING_LEN(src) ? sizeof(buf) : (size_t)RSTRING_LEN(src));
    return rb_str_new(buf, 8);
}

void
Init_api_string_h(void)
{
    rb_define_global_function("api_string_h_copy", m_copy, 1);
}
