#include <ruby.h>

/* ruby.h defines NDEBUG, so CRuby drops the code under #ifndef NDEBUG; the converted mruby output keeps the guard, and
 * its code is live there: the guarded method is converted and registered */
static VALUE mNG;

static VALUE ng_run(VALUE self, VALUE v) {
    return Qtrue;
}

#ifndef NDEBUG
static VALUE ng_guarded(VALUE self, VALUE v) {
    return Qfalse;
}
#endif

void Init_api_ndebug_guard(void) {
    mNG = rb_define_module("NdebugGuard");
    rb_define_module_function(mNG, "run", ng_run, 1);
#ifndef NDEBUG
    rb_define_module_function(mNG, "guarded", ng_guarded, 1);
#endif
}
