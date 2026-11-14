#include <ruby.h>
static VALUE mDv;

static VALUE dv_hi(VALUE self) {
    return Qtrue;
}

#ifdef DV_NEW_API
static void dv_setup(VALUE m) {
    rb_define_module_function(m, "hi", dv_hi, 0);
}
#else
static void dv_setup(VALUE m) {
    rb_define_module_function(m, "hi", dv_hi, 0);
}
#endif

void Init_api_dup_variant(void) {
    mDv = rb_define_module("DupVariant");
    dv_setup(mDv);
}
