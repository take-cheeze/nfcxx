#include <ruby.h>

/* a helper that needs the mruby state (rb_raise) and whose address goes to a library's error setter: the library calls it only
 * inside a call the gem makes, so the helper uses the gem's global state (no refusal); a helper handed to an unknown library
 * function is still refused (the library may keep it) */
extern void xmlSetGenericErrorFunc(void *ctx, void (*handler)(void *ctx, const char *msg));
extern void unknown_lib_keeps(void (*handler)(void *ctx, const char *msg));

static void gcb_error(void *ctx, const char *msg) {
    (void)ctx;
    rb_raise(rb_eRuntimeError, "%s", msg);
}

static void gcb_kept(void *ctx, const char *msg) {
    (void)ctx;
    rb_raise(rb_eRuntimeError, "%s", msg);
}

static VALUE gcb_run(VALUE self) {
    (void)self;
    xmlSetGenericErrorFunc(NULL, gcb_error);
    return Qnil;
}

static VALUE gcb_keep(VALUE self) {
    (void)self;
    unknown_lib_keeps(gcb_kept);
    return Qnil;
}

void Init_api_global_cb(void) {
    VALUE m = rb_define_module("GCB");
    rb_define_module_function(m, "run", gcb_run, 0);
    rb_define_module_function(m, "keep", gcb_keep, 0);
}
