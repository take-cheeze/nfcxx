#include <ruby.h>
static VALUE mHashClass;
static VALUE hc_pairs(VALUE self, VALUE a, VALUE b) {
    VALUE h = rb_hash_new();
    VALUE pairs[4];
    pairs[0] = a;
    pairs[1] = b;
    pairs[2] = b;
    pairs[3] = a;
    rb_hash_bulk_insert(4, pairs, h);
    return h;
}
static VALUE hc_inherits(VALUE self, VALUE sub, VALUE sup) {
    return rb_class_inherited_p(sub, sup);
}
void Init_api_hash_class(void) {
    mHashClass = rb_define_module("HashClass");
    rb_define_module_function(mHashClass, "pairs", hc_pairs, 2);
    rb_define_module_function(mHashClass, "inherits", hc_inherits, 2);
}
