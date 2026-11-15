#include <ruby.h>
static VALUE mComplexApi;
static VALUE cx_make(VALUE self, VALUE re, VALUE im) {
    return rb_complex_new(re, im);
}
static VALUE cx_parts(VALUE self, VALUE c) {
    return rb_ary_new3(2, rb_complex_real(c), rb_complex_imag(c));
}
void Init_api_complex(void) {
    mComplexApi = rb_define_module("ComplexApi");
    rb_define_module_function(mComplexApi, "make", cx_make, 2);
    rb_define_module_function(mComplexApi, "parts", cx_parts, 1);
}
