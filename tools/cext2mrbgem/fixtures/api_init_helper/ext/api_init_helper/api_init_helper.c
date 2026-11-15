#include <ruby.h>

static VALUE eh_noop(VALUE self) {
    return Qnil;
}

void Init_api_init_helper_sub(VALUE puma) {
    VALUE mod, eng;
    mod = rb_define_module_under(puma, "IhSub");
    eng = rb_define_class_under(mod, "Engine", rb_cObject);
    rb_define_method(eng, "inject", eh_noop, 0);
}

void Init_api_init_helper(void) {
    VALUE puma = rb_define_module("InitHelper");
    Init_api_init_helper_sub(puma);
}
