#include <ruby.h>

/* a VALUE-returning inline function used as an if condition: one truth test, not two */
inline static VALUE
tt_zero(VALUE x)
{
    return x == INT2FIX(0) ? Qtrue : Qfalse;
}

static VALUE
tt_check(VALUE self, VALUE x)
{
    if (tt_zero(x))
        return Qtrue;
    return Qfalse;
}

void
Init_api_truth_twice(void)
{
    VALUE m = rb_define_module("TruthTwice");
    rb_define_module_function(m, "check", tt_check, 1);
}
