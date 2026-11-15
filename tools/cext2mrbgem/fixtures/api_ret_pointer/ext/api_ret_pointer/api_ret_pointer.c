#include <ruby.h>
typedef struct { int n; } Real;
static VALUE mRetPtr;
static Real *
rp_ptr(VALUE obj)
{
    Real *vp = 0;
    rb_str_new_cstr("x");
    return vp;
}
static Real *rp_ptr_same(VALUE obj) { Real *vp = 0; return vp; }
static VALUE rp_run(VALUE self, VALUE v) { return rp_ptr(v) ? Qtrue : Qfalse; }
void Init_api_ret_pointer(void) {
    mRetPtr = rb_define_module("RetPtr");
    rb_define_module_function(mRetPtr, "run", rp_run, 1);
}
