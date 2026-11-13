#include <ruby.h>

/* Check_Type and rb_check_type with a literal T_ type that has an exact (or caveated) mruby tag: each becomes
 * mrb_check_type with the MRB_TT_ tag. T_DATA carries its caveat (TypedData is not distinguished). */
static VALUE mCheckType;

static VALUE ct_string(VALUE self, VALUE v) {
    Check_Type(v, T_STRING);
    return v;
}

static VALUE ct_array(VALUE self, VALUE v) {
    rb_check_type(v, T_ARRAY);
    return v;
}

static VALUE ct_data(VALUE self, VALUE v) {
    Check_Type(v, T_DATA);
    return v;
}

void Init_check_type(void) {
    mCheckType = rb_define_module("CheckType");
    rb_define_module_function(mCheckType, "string", ct_string, 1);
    rb_define_module_function(mCheckType, "array", ct_array, 1);
    rb_define_module_function(mCheckType, "data", ct_data, 1);
}
