#include <ruby.h>

static VALUE parse_buf(VALUE str, long len)
{
    VALUE buffer_v;
    char *buffer = RB_ALLOCV_N(char, buffer_v, len + 1);
    VALUE result;
    memcpy(buffer, RSTRING_PTR(str), (size_t)len);
    buffer[len] = '\0';
    result = rb_str_new_cstr(buffer);
    RB_ALLOCV_END(buffer_v);
    return result;
}

static VALUE m_parse(VALUE self, VALUE str)
{
    return parse_buf(str, RSTRING_LEN(str));
}

void Init_api_allocv_pair(void)
{
    rb_define_method(rb_cObject, "parse_buf", m_parse, 1);
}
