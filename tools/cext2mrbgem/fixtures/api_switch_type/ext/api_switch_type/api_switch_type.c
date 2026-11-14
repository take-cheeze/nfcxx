#include <ruby.h>

/* switch (TYPE(v)) with case T_NIL and case T_FALSE: nil is routed to its own case, so false is only MRB_TT_FALSE */
static VALUE mST;

static VALUE st_kind(VALUE self, VALUE v) {
    switch (TYPE(v)) {
    case T_NIL: return rb_str_new_cstr("nil");
    case T_FALSE: return rb_str_new_cstr("false");
    default: return rb_str_new_cstr("other");
    }
}

void Init_api_switch_type(void) {
    mST = rb_define_module("SwitchType");
    rb_define_module_function(mST, "kind", st_kind, 1);
}
