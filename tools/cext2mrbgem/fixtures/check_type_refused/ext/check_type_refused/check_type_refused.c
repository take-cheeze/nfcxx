#include <ruby.h>

/* Check_Type and rb_check_type forms with no exact mruby type test, or with a type argument that is not a literal
 * T_ constant: each stays refused with its reason, and the T_ name is not mapped inside the refused call. */
static VALUE mCheckTypeRefused;

static VALUE ctr_fixnum(VALUE self, VALUE v) {
    Check_Type(v, T_FIXNUM);
    return v;
}

static VALUE ctr_nil(VALUE self, VALUE v) {
    rb_check_type(v, T_NIL);
    return v;
}

static VALUE ctr_class(VALUE self, VALUE v) {
    Check_Type(v, T_CLASS);
    return v;
}

static VALUE ctr_variable(VALUE self, VALUE v) {
    int t = 0;
    rb_check_type(v, t);
    return v;
}

void Init_check_type_refused(void) {
    mCheckTypeRefused = rb_define_module("CheckTypeRefused");
    rb_define_module_function(mCheckTypeRefused, "fixnum", ctr_fixnum, 1);
    rb_define_module_function(mCheckTypeRefused, "nil", ctr_nil, 1);
    rb_define_module_function(mCheckTypeRefused, "klass", ctr_class, 1);
    rb_define_module_function(mCheckTypeRefused, "variable", ctr_variable, 1);
}
