#include <ruby.h>
static VALUE mHashAsetValue;
static VALUE hav_store(VALUE self, VALUE h, VALUE k, VALUE v) {
    return rb_hash_aset(h, k, v);
}
void Init_api_hash_aset_value(void) {
    mHashAsetValue = rb_define_module("HashAsetValue");
    rb_define_module_function(mHashAsetValue, "store", hav_store, 3);
}
