#include <ruby.h>
static VALUE mRts;

static VALUE rts_kind(VALUE self, VALUE v) {
    switch (rb_type(v)) {
    case T_NIL: return rb_str_new_cstr("nil");
    case T_STRING: return rb_str_new_cstr("string");
    case T_HASH: return rb_str_new_cstr("hash");
    default: return rb_str_new_cstr("other");
    }
}

void Init_api_rb_type_switch(void) {
    mRts = rb_define_module("RbTypeSwitch");
    rb_define_module_function(mRts, "kind", rts_kind, 1);
}
