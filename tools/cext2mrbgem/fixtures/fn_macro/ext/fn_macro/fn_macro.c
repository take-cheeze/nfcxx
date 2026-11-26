#include <ruby.h>

/* A function-defining macro invoked at file scope (ffi's NUM_OP): each invocation defines the functions named from its
 * first argument. The converter expands the invocations, so the functions are ordinary definitions and registrations. */
#define DEFINE_GET(name, type, fromNative) \
static VALUE fn_get_##name(VALUE self) { return fromNative((type) 1); } \
static VALUE fn_get2_##name(VALUE self) { return fromNative((type) 2); }

DEFINE_GET(int, int, INT2NUM);
DEFINE_GET(long, long, LONG2NUM);

void
Init_fn_macro(void)
{
    VALUE mFn = rb_define_module("FnMacro");
    rb_define_method(mFn, "get_int", fn_get_int, 0);
    rb_define_method(mFn, "get_long", fn_get_long, 0);
    rb_define_method(mFn, "get2_long", fn_get2_long, 0);
}
