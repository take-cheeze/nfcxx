#include <ruby.h>

#define NORETURN(x) x __attribute__((api_noreturnurn))

NORETURN(static void anr_fail(VALUE v));

static VALUE mAnr;

static void anr_fail(VALUE v) {
    rb_raise(rb_eArgError, "bad");
}

static VALUE anr_run(VALUE self, VALUE v) {
    anr_fail(v);
    return Qnil;
}

void Init_api_noreturn(void) {
    mAnr = rb_define_module("Anr");
    rb_define_module_function(mAnr, "run", anr_run, 1);
}
