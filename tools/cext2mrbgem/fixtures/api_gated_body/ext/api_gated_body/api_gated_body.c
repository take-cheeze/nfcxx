#include <ruby.h>

/* a helper under an #if that this build leaves false: its body is not compiled, so a use of an
 * mruby-needing name inside it is not a file-scope use (the converter keeps the guard) */
static VALUE mGated;

#ifdef GATED_TEST_METHODS
static VALUE gated_helper(VALUE self, VALUE r) {
    return NUM2INT(r) ? Qtrue : Qfalse;
}
#endif

static VALUE g_check(VALUE self, VALUE r) {
    return Qnil;
}

void Init_api_gated_body(void) {
    mGated = rb_define_module("GatedBody");
    rb_define_module_function(mGated, "check", g_check, 1);
}
