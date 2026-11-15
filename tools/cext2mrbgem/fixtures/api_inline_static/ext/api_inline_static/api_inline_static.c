#include <ruby.h>
static VALUE mInlineStatic;
VALUE other_run(VALUE self, VALUE v);
inline static VALUE is_first(VALUE v) {
    return rb_funcall(v, rb_intern("to_s"), 0);
}
static VALUE is_run(VALUE self, VALUE v) {
    return is_first(v);
}
void Init_api_inline_static(void) {
    mInlineStatic = rb_define_module("InlineStatic");
    rb_define_module_function(mInlineStatic, "run", is_run, 1);
    rb_define_module_function(mInlineStatic, "other", other_run, 1);
}
