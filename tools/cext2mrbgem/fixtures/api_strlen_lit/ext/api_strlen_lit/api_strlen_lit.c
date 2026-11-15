#include <ruby.h>
static VALUE mStrlenLit;
static VALUE sl_len(VALUE self) {
    char fmt[rb_strlen_lit(".%N") + 4];
    fmt[0] = 0;
    return INT2FIX((int)rb_strlen_lit(".%N"));
}
void Init_api_strlen_lit(void) {
    mStrlenLit = rb_define_module("StrlenLit");
    rb_define_module_function(mStrlenLit, "len", sl_len, 0);
}
