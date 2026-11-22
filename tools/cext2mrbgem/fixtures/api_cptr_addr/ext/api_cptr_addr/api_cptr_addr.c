#include <ruby.h>

/* The address of a struct stored as a VALUE (CRuby's (VALUE)&s): a CPTR value in the fork. */
typedef struct { int n; } Slot;

static VALUE
ca_wrap(VALUE self, VALUE x)
{
    Slot s;
    s.n = 1;
    return (VALUE)&s;
}

void
Init_api_cptr_addr(void)
{
    VALUE m = rb_define_module("CptrAddr");
    rb_define_module_function(m, "wrap", ca_wrap, 1);
}
