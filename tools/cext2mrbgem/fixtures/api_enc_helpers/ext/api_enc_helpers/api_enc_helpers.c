#include <ruby.h>

/* the encoding helpers: a codepoint of a UTF-8 string, a conversion of a string into an encoding, the name of an encoding,
   and rb_enc_raise (the encoding of the message is dropped: the fork's messages are not tagged) */
static VALUE
eh_codepoint(VALUE self, VALUE str)
{
    int len = 0;
    char *p = RSTRING_PTR(str);
    unsigned int cp = rb_enc_codepoint_len(p, p + RSTRING_LEN(str), &len, rb_utf8_encoding());
    return rb_ary_new3(2, UINT2NUM(cp), INT2FIX(len));
}

static VALUE
eh_conv(VALUE self, VALUE str)
{
    return rb_str_conv_enc(str, rb_utf8_encoding(), rb_usascii_encoding());
}

static VALUE
eh_name(VALUE self)
{
    return rb_enc_from_encoding(rb_utf8_encoding());
}

static VALUE
eh_fail(VALUE self, VALUE msg)
{
    rb_enc_raise(rb_utf8_encoding(), rb_eEncodingError, "bad: %s", StringValueCStr(msg));
    return Qnil;
}

void
Init_api_enc_helpers(void)
{
    VALUE m = rb_define_module("EncHelpers");
    rb_define_module_function(m, "codepoint", eh_codepoint, 1);
    rb_define_module_function(m, "conv", eh_conv, 1);
    rb_define_module_function(m, "name", eh_name, 0);
    rb_define_module_function(m, "fail", eh_fail, 1);
}
