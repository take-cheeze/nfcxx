#include <ruby.h>

/* RUBY_TYPED_* flags (api_map.json batch N9): mruby has no such flags, so they map to 0 with a caveat */
static VALUE mApiFlags;

static VALUE api_flags(VALUE self) {
    int flags = RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED;
    return INT2NUM(flags);
}

void Init_api_typed_flags(void) {
    mApiFlags = rb_define_module("ApiFlags");
    rb_define_module_function(mApiFlags, "flags", api_flags, 0);
}
