#include <ruby.h>

static VALUE dm_noop(VALUE self) {
    return Qnil;
}

void Init_api_decl_mixed(void) {
    VALUE a = Qnil, eng = rb_define_class("DeclMixed", rb_cObject), b = Qnil;
    (void)a;
    (void)b;
    rb_define_method(eng, "noop", dm_noop, 0);
}
