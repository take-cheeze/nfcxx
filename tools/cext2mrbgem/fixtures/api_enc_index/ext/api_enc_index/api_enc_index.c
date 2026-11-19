#include <ruby.h>

/* the encoding index API: an index of a string, the US-ASCII encoding, the index lookup by name, a character count, and the
   EncodingError class (raised by rb_raise) */
static VALUE
ei_index(VALUE self, VALUE str)
{
    int i = RB_ENCODING_GET(str);
    if (i == rb_usascii_encindex()) return INT2FIX(2);
    return INT2FIX(i);
}

static VALUE
ei_chars(VALUE self, VALUE str)
{
    char *p = RSTRING_PTR(str);
    long n = rb_enc_strlen(p, p + RSTRING_LEN(str), rb_utf8_encoding());
    return LONG2NUM(n);
}

static VALUE
ei_find(VALUE self, VALUE name)
{
    return INT2FIX(rb_enc_find_index(StringValueCStr(name)));
}

static VALUE
ei_tag(VALUE self, VALUE str)
{
    ENCODING_SET(str, rb_usascii_encindex());
    return str;
}

static VALUE
ei_fail(VALUE self)
{
    rb_raise(rb_eEncodingError, "bad encoding");
    return Qnil;
}

void
Init_api_enc_index(void)
{
    VALUE m = rb_define_module("EncIndex");
    rb_define_module_function(m, "index", ei_index, 1);
    rb_define_module_function(m, "chars", ei_chars, 1);
    rb_define_module_function(m, "find", ei_find, 1);
    rb_define_module_function(m, "tag", ei_tag, 1);
    rb_define_module_function(m, "fail", ei_fail, 0);
}
