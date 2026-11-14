#include <ruby.h>
static VALUE cCot;

static VALUE cot_helper(VALUE self) {
    return Qnil;
}

void Init_api_class_of_target(void) {
    cCot = rb_define_class("ClassOfTarget", rb_cObject);
    rb_define_private_method(CLASS_OF(cCot), "helper", cot_helper, 0);
}
