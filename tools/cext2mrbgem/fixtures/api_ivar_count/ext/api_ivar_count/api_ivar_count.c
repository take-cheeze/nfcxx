#include <ruby.h>
static VALUE mIvarCount;
static VALUE ic_count(VALUE self, VALUE obj) {
    return SIZET2NUM(rb_ivar_count(obj));
}
void Init_api_ivar_count(void) {
    mIvarCount = rb_define_module("IvarCount");
    rb_define_module_function(mIvarCount, "count", ic_count, 1);
}
