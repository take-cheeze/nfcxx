#include <ruby.h>

/* RB_TYPE_P forms with no exact mruby comparison, or not a plain local: each stays refused with its reason. */
static VALUE mTypeRefused;

static VALUE tr_data(VALUE self, VALUE obj) {
    if (RB_TYPE_P(obj, T_DATA)) return Qtrue;
    return Qfalse;
}

static VALUE tr_nested(VALUE self, VALUE a) {
    if (RB_TYPE_P(rb_ary_entry(a, 0), T_STRING)) return Qtrue;
    return Qfalse;
}

static VALUE tr_fixnum(VALUE self, VALUE obj) {
    if (RB_TYPE_P(obj, T_FIXNUM)) return Qtrue;
    return Qfalse;
}

static VALUE tr_nil(VALUE self, VALUE obj) {
    if (RB_TYPE_P(obj, T_NIL)) return Qtrue;
    return Qfalse;
}

void Init_api_type_refused(void) {
    mTypeRefused = rb_define_module("TypeRefused");
    rb_define_module_function(mTypeRefused, "data", tr_data, 1);
    rb_define_module_function(mTypeRefused, "nested", tr_nested, 1);
    rb_define_module_function(mTypeRefused, "fixnum", tr_fixnum, 1);
    rb_define_module_function(mTypeRefused, "nil", tr_nil, 1);
}
