#include <ruby.h>

/* A macro that calls the state's API, expanded in a registered method: it has no mrb argument, so it runs on the file-scope
 * global state (set on entry to the method). GlobalEscape.call's exception (BasicObject has no to_s) escapes the method by
 * longjmp, so the method's restore of the global must also run on the exception path. */
#define GE_TO_S(x) rb_funcall((x), rb_intern("to_s"), 0)

static VALUE
ge_call(VALUE self, VALUE obj)
{
    return GE_TO_S(obj);
}

void
Init_global_escape(void)
{
    VALUE m = rb_define_module("GlobalEscape");
    rb_define_module_function(m, "call", ge_call, 1);
}
