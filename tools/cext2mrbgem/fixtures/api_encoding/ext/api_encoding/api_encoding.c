#include <ruby.h>

/* the encoding API of the gem: the encoding of a string, and the encodings a new string gets */
static VALUE
m_enc_of(VALUE self, VALUE str)
{
    return rb_enc_get(str);
}

static VALUE
m_binary(VALUE self, VALUE str)
{
    return rb_enc_associate(str, rb_ascii8bit_encoding());
}

static VALUE
m_utf8(VALUE self, VALUE str)
{
    return rb_enc_associate(str, rb_utf8_encoding());
}

void
Init_api_encoding(void)
{
    VALUE c = rb_define_class("EncApi", rb_cObject);
    rb_define_method(c, "enc_of", m_enc_of, 1);
    rb_define_method(c, "binary", m_binary, 1);
    rb_define_method(c, "utf8", m_utf8, 1);
}
