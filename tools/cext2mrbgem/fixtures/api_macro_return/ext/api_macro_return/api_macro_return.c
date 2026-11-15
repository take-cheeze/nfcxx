#include <ruby.h>
static VALUE mMacroRet;
static VALUE mret_make(VALUE s) { return rb_str_dup(s); }
#define MRET_RET(s) \
do { \
    return mret_make(s); \
} while (0)
static VALUE mret_run(VALUE self, VALUE s) {
    MRET_RET(s);
}
void Init_api_macro_return(void) {
    mMacroRet = rb_define_module("MacroRet");
    rb_define_module_function(mMacroRet, "run", mret_run, 1);
}
