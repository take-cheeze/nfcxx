#include <ruby.h>

/* mdn_name is a registered method that calls the mruby state's API (rb_str_new). It is also called directly by mdn_cb, a
 * thread body whose address goes to rb_thread_create: mdn_cb is refused (its pointer escapes) and has no state argument.
 * The gem has no Init (its methods are registered by mdn_register), so no state is set outside a method: the direct call has no state, and mdn_name keeps its refusal. */
static VALUE mdn_name(VALUE self) {
    return rb_str_new_cstr("name");
}

static VALUE mdn_cb(void *p) {
    return mdn_name(Qnil);
}

static VALUE mdn_start(VALUE self) {
    return rb_thread_create(mdn_cb, NULL);
}


static void mdn_register(void) {
    VALUE m = rb_define_module("MethodDirectNoinit");
    rb_define_module_function(m, "name", mdn_name, 0);
    rb_define_module_function(m, "start", mdn_start, 0);
}
