#include <ruby.h>

/* StringValue(x) assigns the converted String back to x (api_map.json batch N4) */
static VALUE mApiStr;

static VALUE api_len(VALUE self, VALUE s) {
    StringValue(s);
    return LONG2NUM(RSTRING_LEN(s));
}

void Init_api_string_value(void) {
    mApiStr = rb_define_module("ApiStr");
    rb_define_module_function(mApiStr, "len", api_len, 1);
}
