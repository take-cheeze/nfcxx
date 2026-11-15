#include <ruby.h>
typedef void (*DumpFunc)(VALUE obj, int depth);
static VALUE mDispatch;
static void dt_nil(VALUE obj, int depth) {
    if (NIL_P(obj)) rb_raise(rb_eTypeError, "nil at depth %d", depth);
}
static void dt_str(VALUE obj, int depth) {
    rb_funcall(obj, rb_intern("to_s"), 0);
}
static DumpFunc dt_funcs[] = { dt_nil, dt_str };
static void dt_dispatch(VALUE obj, int depth) {
    dt_funcs[NIL_P(obj) ? 0 : 1](obj, depth);
}
static VALUE dt_run(VALUE self, VALUE obj) {
    dt_dispatch(obj, 0);
    return Qnil;
}
void Init_api_dispatch_table(void) {
    mDispatch = rb_define_module("DispatchTable");
    rb_define_module_function(mDispatch, "run", dt_run, 1);
}
