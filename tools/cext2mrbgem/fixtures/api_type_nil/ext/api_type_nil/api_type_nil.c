#include <ruby.h>

/* TYPE(v) == T_NIL and TYPE(v) != T_FALSE are value tests (nil and false share a type tag): mrb_nil_p and mrb_false_p */
static VALUE mTN;

static VALUE tn_is_nil(VALUE self, VALUE v) {
    return TYPE(v) == T_NIL ? Qtrue : Qfalse;
}

static VALUE tn_not_false(VALUE self, VALUE v) {
    return TYPE(v) != T_FALSE ? Qtrue : Qfalse;
}

void Init_api_type_nil(void) {
    mTN = rb_define_module("TypeNil");
    rb_define_module_function(mTN, "nil?", tn_is_nil, 1);
    rb_define_module_function(mTN, "not_false?", tn_not_false, 1);
}
