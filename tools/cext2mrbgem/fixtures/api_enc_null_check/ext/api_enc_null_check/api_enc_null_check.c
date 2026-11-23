#include <ruby.h>

/* msgpack's null-encoding check of an interned empty string: RB_ENC_INTERNED_STR_NULL_CHECK is a CRuby build flag (1 only for
   Ruby 3.0.0 to 3.0.5, the ruby bug 18772 workaround), so the branch is the default 0 for this port */
#ifndef RB_ENC_INTERNED_STR_NULL_CHECK
#define RB_ENC_INTERNED_STR_NULL_CHECK 0
#endif

static VALUE
enc_empty(VALUE self, VALUE len)
{
    if (RB_ENC_INTERNED_STR_NULL_CHECK && NUM2LONG(len) == 0) {
        return rb_str_new_cstr("");
    }
    return rb_str_new_cstr("x");
}

void
Init_api_enc_null_check(void)
{
    VALUE m = rb_define_module("EncNullCheck");
    rb_define_module_function(m, "empty", enc_empty, 1);
}
