#include <ruby.h>
#define VP_EXPORT static
static VALUE mStorageMacro;
VP_EXPORT VALUE vp_hello(VALUE self) {
    return rb_str_new_cstr("hello");
}
void Init_api_storage_macro(void) {
    mStorageMacro = rb_define_module("StorageMacro");
    rb_define_module_function(mStorageMacro, "hello", vp_hello, 0);
}
