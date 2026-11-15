#include <ruby.h>
static VALUE mMiscNames;
static VALUE mn_attr(VALUE self, VALUE obj) {
    return rb_attr_get(obj, rb_intern("@x"));
}
static VALUE mn_hash(VALUE self, VALUE v) {
    return rb_check_hash_type(v);
}
static VALUE mn_set(VALUE self, VALUE s, VALUE v) {
    rb_struct_aset(s, INT2FIX(0), v);
    return v;
}
static VALUE mn_nil(VALUE self) {
    RB_EXT_RACTOR_SAFE(true);
    return RUBY_Qnil;
}
void Init_api_misc_names(void) {
    mMiscNames = rb_define_module("MiscNames");
    rb_define_module_function(mMiscNames, "attr", mn_attr, 1);
    rb_define_module_function(mMiscNames, "hash", mn_hash, 1);
    rb_define_module_function(mMiscNames, "set", mn_set, 2);
    rb_define_module_function(mMiscNames, "nilv", mn_nil, 0);
}
