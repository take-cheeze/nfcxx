#include <ruby.h>
static VALUE mStrFormat;
static VALUE sf_pad(VALUE self, VALUE w, VALUE v) {
    VALUE args[2];
    args[0] = w;
    args[1] = v;
    return rb_str_format(2, args, rb_str_new_cstr("%*d"));
}
void Init_api_str_format(void) {
    mStrFormat = rb_define_module("StrFormat");
    rb_define_module_function(mStrFormat, "pad", sf_pad, 2);
}
