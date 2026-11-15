#include <ruby.h>
static VALUE mDirectNull;
static VALUE dn_today(int argc, VALUE *argv, VALUE klass) {
    return klass;
}
static VALUE dn_call(VALUE self) {
    return dn_today(0, (VALUE *)0, mDirectNull);
}
void Init_api_direct_null(void) {
    mDirectNull = rb_define_module("DirectNull");
    rb_define_module_function(mDirectNull, "today", dn_today, -1);
    rb_define_module_function(mDirectNull, "call", dn_call, 0);
}
