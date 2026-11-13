#include <ruby.h>

/* A helper taken as a value (not a direct call) and a helper name shadowed by a local: both stay refused. */
static VALUE ht_cb(VALUE s) {
    return rb_str_new_cstr("cb");
}

static VALUE ht_shadow_helper(VALUE s) {
    return rb_str_new_cstr("shadow");
}

static VALUE htr_pointer(VALUE self, VALUE s) {
    VALUE (*fp)(VALUE) = ht_cb;
    return fp(s);
}

static VALUE htr_shadow(VALUE self, VALUE s) {
    VALUE (*ht_shadow_helper)(VALUE) = NULL;
    return ht_shadow_helper(s);
}

void Init_helper_thread_refused(void) {
    VALUE m = rb_define_module("HelperThreadRefused");
    rb_define_module_function(m, "pointer", htr_pointer, 1);
    rb_define_module_function(m, "shadow", htr_shadow, 1);
}
