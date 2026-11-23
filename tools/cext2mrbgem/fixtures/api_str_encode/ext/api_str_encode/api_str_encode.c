#include <ruby.h>

/* rb_str_encode(str, enc, 0, Qnil): a string transcoded to UTF-8 (msgpack's packer for a non-UTF-8-compatible string). */
static VALUE
se_to_utf8(VALUE self, VALUE str)
{
    VALUE enc = rb_enc_from_encoding(rb_utf8_encoding());
    return rb_str_encode(str, enc, 0, Qnil);
}

void
Init_api_str_encode(void)
{
    VALUE m = rb_define_module("StrEncode");
    rb_define_module_function(m, "to_utf8", se_to_utf8, 1);
}
