#include <ruby.h>

/* rb_define_module_function (singleton and private instance method) and rb_define_const on a tracked module. */
static VALUE mMC;
static VALUE cMCHelper;

static VALUE mc_twice(VALUE self, VALUE x) {
    return INT2FIX(FIX2INT(x) * 2);
}

static VALUE mc_argc(int argc, VALUE *argv, VALUE self) {
    return INT2FIX(argc);
}

void Init_module_const(void) {
    mMC = rb_define_module("ModuleConst");
    cMCHelper = rb_define_class_under(mMC, "Helper", rb_cObject);
    rb_define_module_function(mMC, "twice", mc_twice, 1);
    rb_define_module_function(mMC, "argc", mc_argc, -1);
    rb_define_const(mMC, "VERSION", INT2FIX(3));
    rb_define_const(rb_cObject, "MODULE_CONST_LOADED", Qtrue);
}
