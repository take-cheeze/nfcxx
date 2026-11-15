#include <ruby.h>

static VALUE ccr_shout(VALUE self) {
    return self;
}

void Init_api_core_class_reg(void) {
    rb_define_method(rb_cString, "shout", ccr_shout, 0);
    rb_define_const(rb_cString, "CCR_LIMIT", INT2FIX(5));
}
