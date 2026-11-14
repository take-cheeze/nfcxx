#include <ruby.h>

/* a local named like a helper: used without a call (a variable), it is not a use of the helper, so the helper converts;
 * a direct call through the same name in another function is still refused (the name is then not the helper) */
static VALUE mSL;

static VALUE sl_check(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

static VALUE sl_run(VALUE self, VALUE v) {
    VALUE sl_check = Qfalse;
    sl_check = Qtrue;
    return sl_check;
}

static VALUE sl_use(VALUE self, VALUE v) {
    return sl_check(v);
}

void Init_api_shadow_local(void) {
    mSL = rb_define_module("ShadowLocal");
    rb_define_module_function(mSL, "run", sl_run, 1);
    rb_define_module_function(mSL, "use", sl_use, 1);
}
