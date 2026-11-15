#include <ruby.h>
static VALUE mFnptrThread;
static VALUE fp_double(VALUE i) {
    return rb_funcall(i, rb_intern("*"), 1, INT2FIX(2));
}
static VALUE fp_add1(VALUE i) {
    return rb_funcall(i, rb_intern("+"), 1, INT2FIX(1));
}
static VALUE fp_apply(VALUE i, VALUE (*conv1)(VALUE), VALUE (*conv2)(VALUE)) {
    VALUE c = (*conv1)(i);
    VALUE o = (*conv2)(c);
    return o == i ? Qtrue : Qfalse;
}
static VALUE fp_run(VALUE self, VALUE i) {
    return fp_apply(i, fp_double, fp_add1);
}
void Init_api_fnptr_thread(void) {
    mFnptrThread = rb_define_module("FnptrThread");
    rb_define_module_function(mFnptrThread, "run", fp_run, 1);
}
