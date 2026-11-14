#include <ruby.h>
static VALUE mEDDrop;
static VALUE ed_make(VALUE self, VALUE s) {
    char *p = RSTRING_PTR(s);
    long n = RSTRING_LEN(s);
    return rb_enc_str_new(p, n, rb_utf8_encoding());
}
static VALUE ed_tag(VALUE self, VALUE s) {
    return rb_enc_associate(s, rb_utf8_encoding());
}
void Init_api_enc_drop(void) {
    mEDDrop = rb_define_module("EncDrop");
    rb_define_module_function(mEDDrop, "make", ed_make, 1);
    rb_define_module_function(mEDDrop, "tag", ed_tag, 1);
}
