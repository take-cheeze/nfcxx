#include <ruby.h>
static VALUE mSp;

static VALUE sp_describe(VALUE self, VALUE v) {
    return rb_sprintf("#<%"PRIsVALUE" value=%+"PRIsVALUE">", rb_obj_class(v), v);
}

void Init_api_sprintf_pv(void) {
    mSp = rb_define_module("SprintfPv");
    rb_define_module_function(mSp, "describe", sp_describe, 1);
}
