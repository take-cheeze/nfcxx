#include <ruby.h>
static VALUE mMacroRetRestore;
#define RETURN_FALSE_UNLESS_NUMERIC(obj) if (!RTEST(rb_obj_is_kind_of((obj), rb_cNumeric))) return Qfalse
static VALUE mrr_check(VALUE self, VALUE obj) {
    RETURN_FALSE_UNLESS_NUMERIC(obj);
    return Qtrue;
}
void Init_api_macro_ret_restore(void) {
    mMacroRetRestore = rb_define_module("MacroRetRestore");
    rb_define_module_function(mMacroRetRestore, "numeric?", mrr_check, 1);
}
