#include <ruby.h>
enum { RUBY_TAG_LOCAL = 3, OTHER_TAG = 1 };
static VALUE mEnumLocal;
static VALUE el_tag(VALUE self, VALUE v) {
    if (RUBY_TAG_LOCAL == 3) return rb_str_new_cstr("local");
    return v;
}
void Init_api_enum_local(void) {
    mEnumLocal = rb_define_module("EnumLocal");
    rb_define_module_function(mEnumLocal, "tag", el_tag, 1);
}
