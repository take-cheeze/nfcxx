#include <ruby.h>

/* Two macros that call the state's API and get no global-state marker. DM_OLD_RAISE is defined and used only in an #if 0
 * block: it is inactive in this build, so it is dead text. DM_UNUSED_RAISE has no use in the gem: the converter keeps it
 * under #if 0 as an unused macro. DM_TO_S is used by a registered method, so it keeps the marker (its global state). */
#if 0
#define DM_OLD_RAISE(msg) rb_raise(rb_eArgError, "%s", (msg))
static VALUE
dm_old(VALUE self)
{
    DM_OLD_RAISE("old");
    return Qnil;
}
#endif

#define DM_UNUSED_RAISE(msg) rb_raise(rb_eArgError, "%s", (msg))

#define DM_TO_S(x) rb_funcall((x), rb_intern("to_s"), 0)

static VALUE
dm_call(VALUE self, VALUE obj)
{
    return DM_TO_S(obj);
}

void
Init_disabled_macro(void)
{
    VALUE m = rb_define_module("DisabledMacro");
    rb_define_module_function(m, "call", dm_call, 1);
}
