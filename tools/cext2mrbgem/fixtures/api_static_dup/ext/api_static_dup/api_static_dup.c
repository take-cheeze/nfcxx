#include <ruby.h>

/* A static helper with the same name in two files (api_map.json batch N16): each file's copy is local */
static int sd_check(VALUE v) {
    if (NIL_P(v)) {
        rb_raise(rb_eArgError, "nil");
    }
    return 1;
}

static VALUE mSd;

static VALUE sd_run(VALUE self, VALUE v) {
    return INT2NUM(sd_check(v) + sd_other(v));
}

void Init_api_static_dup(void) {
    mSd = rb_define_module("SD");
    rb_define_module_function(mSd, "run", sd_run, 1);
}
