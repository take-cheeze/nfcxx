#include <ruby.h>

/* (VALUE) casts of VALUE operands are identities: the ensure data is the VALUE itself */
static VALUE vci_body(VALUE data) { return data; }
static VALUE vci_clean(VALUE data) { return data; }

static VALUE vci_run(VALUE self, VALUE ctx) {
    VALUE held = (VALUE)ctx;
    return rb_ensure(vci_body, (VALUE)self, vci_clean, (VALUE)held);
}

void Init_value_cast_identity(void) {
    VALUE m = rb_define_module("ValueCastIdentity");
    rb_define_method(m, "run", vci_run, 1);
}
