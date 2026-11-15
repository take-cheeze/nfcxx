#include <ruby.h>
static VALUE mCopyIvar;
static VALUE ci_copy(VALUE self, VALUE dst, VALUE src) {
    rb_copy_generic_ivar(dst, src);
    return dst;
}
void Init_api_copy_ivar(void) {
    mCopyIvar = rb_define_module("CopyIvar");
    rb_define_module_function(mCopyIvar, "copy", ci_copy, 2);
}
