#include <ruby.h>

/* control: rb_args is a VALUE array (it decays to a pointer), so (VALUE)rb_args is a pointer cast, not an identity: refused */
static VALUE vcir_body(VALUE data) { return data; }
static VALUE vcir_clean(VALUE data) { return data; }

static VALUE vcir_run(VALUE self, VALUE ctx) {
    VALUE rb_args[2];
    rb_args[0] = self;
    rb_args[1] = ctx;
    return rb_ensure(vcir_body, (VALUE)rb_args, vcir_clean, Qnil);
}

void Init_value_cast_identity_refused(void) {
    VALUE m = rb_define_module("ValueCastIdentityRefused");
    rb_define_method(m, "run", vcir_run, 1);
}
