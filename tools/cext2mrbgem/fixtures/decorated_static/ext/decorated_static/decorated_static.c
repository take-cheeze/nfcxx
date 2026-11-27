#include <ruby.h>

/* Decorator macros as json's json.h defines them: the attribute goes in front of the declaration. The converter expands
 * ALWAYS_INLINE(static) and NOINLINE(static) at the start of a line, so the definitions below are ordinary static
 * definitions to the scanners (before, the definitions were refused: "a macro-decorated definition"). */
#ifndef NOINLINE
#define NOINLINE(x) __attribute__((noinline)) x
#endif
#ifndef ALWAYS_INLINE
#define ALWAYS_INLINE(x) inline __attribute__((always_inline)) x
#endif

ALWAYS_INLINE(static) VALUE
ds_greeting(VALUE name)
{
    return rb_str_dup(name);
}

NOINLINE(static) VALUE ds_wrap(VALUE name)
{
    return ds_greeting(name);
}

static VALUE
ds_greet(VALUE self, VALUE name)
{
    return ds_wrap(name);
}

void
Init_decorated_static(void)
{
    VALUE mDs = rb_define_module("DecoratedStatic");
    rb_define_method(mDs, "greet", ds_greet, 1);
}
