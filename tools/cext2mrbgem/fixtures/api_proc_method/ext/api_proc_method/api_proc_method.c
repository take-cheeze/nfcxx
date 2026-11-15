#include <ruby.h>
static VALUE mProcMethod;
static ID pm_hset_id;
static VALUE pm_check(VALUE self, VALUE obj) {
    return rb_method_boundp(obj, pm_hset_id, 1) ? Qtrue : Qfalse;
}
static VALUE pm_call(VALUE self, VALUE proc, VALUE arg) {
    return rb_proc_call_with_block(proc, 1, &arg, Qnil);
}
void Init_api_proc_method(void) {
    mProcMethod = rb_define_module("ProcMethod");
    pm_hset_id = rb_intern("[]=");
    rb_define_module_function(mProcMethod, "check", pm_check, 1);
    rb_define_module_function(mProcMethod, "call", pm_call, 2);
}
