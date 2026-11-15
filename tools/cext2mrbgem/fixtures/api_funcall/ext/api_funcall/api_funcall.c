#include <ruby.h>
static VALUE mFuncall;
static VALUE fc_run(VALUE self, VALUE v) {
    VALUE a = rb_funcall(v, rb_intern("to_i"), 0);
    VALUE b = rb_funcall(a, '*', 1, INT2FIX(-1));
    VALUE c = rb_funcall(INT2FIX(10), rb_intern("**"), 2, b, SSIZET2NUM(3));
    return c;
}
struct fc_box { VALUE value; };
static VALUE fc_guard(VALUE self, VALUE v) {
    struct fc_box box;
    box.value = rb_str_new_cstr("g");
    RB_GC_GUARD(box.value);
    return v;
}
void Init_api_funcall(void) {
    mFuncall = rb_define_module("Funcall");
    rb_define_module_function(mFuncall, "run", fc_run, 1);
    rb_define_module_function(mFuncall, "guard", fc_guard, 1);
}
