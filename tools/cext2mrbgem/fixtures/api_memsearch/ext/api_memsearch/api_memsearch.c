#include <ruby.h>

static VALUE m_find(VALUE self, VALUE hay, VALUE needle)
{
    long pos = rb_memsearch(RSTRING_PTR(needle), RSTRING_LEN(needle),
                            RSTRING_PTR(hay), RSTRING_LEN(hay), NULL);
    return LONG2NUM(pos);
}

void Init_api_memsearch(void)
{
    rb_define_method(rb_cObject, "find_bytes", m_find, 2);
}
