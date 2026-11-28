#include <ruby.h>

/* mdi_name is a registered method that calls the mruby state's API (rb_str_new). It is also called directly by mdi_cb, a
 * thread body whose address goes to rb_thread_create: mdi_cb is refused (its pointer escapes) and has no state argument.
 * The gem has an Init, which sets the file-scope state, so the direct call reads the global: mdi_name is not refused. */
static VALUE mdi_name(VALUE self) {
    return rb_str_new_cstr("name");
}

static VALUE mdi_cb(void *p) {
    return mdi_name(Qnil);
}

static VALUE mdi_start(VALUE self) {
    return rb_thread_create(mdi_cb, NULL);
}

void Init_method_direct_init(void) {
    VALUE m = rb_define_module("MethodDirectInit");
    rb_define_module_function(m, "name", mdi_name, 0);
    rb_define_module_function(m, "start", mdi_start, 0);
}
