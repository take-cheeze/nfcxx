#include <ruby.h>

/* Prototype only: the definition is absent from the input, so the registration below is refused.
 * The prototype must not crash the converter (the registered-header path used to assume a valid registration). */
static VALUE rr_missing(VALUE self, VALUE a);

static VALUE rr_present(VALUE self) {
    return Qnil;
}

void Init_refused_reg(void) {
    VALUE cRefusedReg = rb_define_class("RefusedReg", rb_cObject);
    rb_define_method(cRefusedReg, "missing", rr_missing, 1);
    rb_define_method(cRefusedReg, "present", rr_present, 0);
}
