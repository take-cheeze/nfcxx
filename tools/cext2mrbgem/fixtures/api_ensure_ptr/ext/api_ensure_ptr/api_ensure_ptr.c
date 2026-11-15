#include <ruby.h>
struct EnsureArg { VALUE obj; int count; };
static VALUE mEnsurePtr;
static VALUE ensure_body(VALUE a) {
    struct EnsureArg *arg = (struct EnsureArg *)a;
    arg->count++;
    return arg->obj;
}
static VALUE ensure_done(VALUE a) {
    struct EnsureArg *arg = (struct EnsureArg *)a;
    arg->count = -1;
    return Qnil;
}
static VALUE ensure_call(VALUE self, VALUE obj) {
    struct EnsureArg arg;
    arg.obj = obj;
    arg.count = 0;
    return rb_ensure(ensure_body, (VALUE)&arg, ensure_done, (VALUE)&arg);
}
void Init_api_ensure_ptr(void) {
    mEnsurePtr = rb_define_module("EnsurePtr");
    rb_define_module_function(mEnsurePtr, "call", ensure_call, 1);
}
