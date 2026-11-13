#include <ruby.h>
#include "helper_thread.h"

static VALUE mHT;

/* static helper: called only in this file */
static VALUE ht_static(VALUE s) {
    return rb_str_new_cstr("static");
}

/* non-static helper with a header declaration; it needs mruby state through ht_static */
VALUE ht_wrap(VALUE self, VALUE s) {
    return ht_static(s);
}

static VALUE ht_call(VALUE self, VALUE s) {
    return ht_wrap(self, s);
}

void Init_helper_thread(void) {
    mHT = rb_define_module("HelperThread");
    rb_define_module_function(mHT, "call", ht_call, 1);
    rb_define_module_function(mHT, "other", ht_other, 1);
}
