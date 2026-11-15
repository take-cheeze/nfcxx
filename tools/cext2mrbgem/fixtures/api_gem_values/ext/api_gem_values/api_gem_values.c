#include <ruby.h>
static VALUE mGemValues;
static VALUE gv_rat(VALUE self, VALUE n, VALUE d) {
    VALUE r = rb_rational_new2(n, d);
    return rb_rational_num(r);
}
static VALUE gv_struct(VALUE self, VALUE s) {
    long n = RSTRUCT_LEN(s);
    VALUE v = RSTRUCT_GET(s, 0);
    VALUE i = INT2FIX(1);
    VALUE w = rb_struct_aref(s, i);
    return n > 0 ? v : w;
}
void Init_api_gem_values(void) {
    mGemValues = rb_define_module("GemValues");
    rb_define_module_function(mGemValues, "rat", gv_rat, 2);
    rb_define_module_function(mGemValues, "struct", gv_struct, 1);
}
