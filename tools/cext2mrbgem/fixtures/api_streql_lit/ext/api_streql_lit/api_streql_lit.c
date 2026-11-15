#include <ruby.h>
static VALUE mSl;

static VALUE sl_is_add(VALUE self, VALUE s) {
    if (rb_streql_lit(s, "add")) return Qtrue;
    return Qfalse;
}

void Init_api_streql_lit(void) {
    mSl = rb_define_module("StreqlLit");
    rb_define_module_function(mSl, "add?", sl_is_add, 1);
}
