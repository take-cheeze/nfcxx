#include <ruby.h>

/* RB_OBJ_FROZEN_RAW: the frozen bit of a String's flags (msgpack's buffer check). */
static VALUE
fr_check(VALUE self, VALUE str)
{
    if (RB_OBJ_FROZEN_RAW(str)) return Qtrue;
    return Qfalse;
}

void
Init_api_frozen_raw(void)
{
    VALUE m = rb_define_module("FrozenRaw");
    rb_define_module_function(m, "check", fr_check, 1);
}
