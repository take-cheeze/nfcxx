#include <ruby.h>

/* A pointer typedef cast of a VALUE (CRuby's (Ctx)x, where Ctx is a struct pointer typedef): read with mrb_cptr. */
typedef struct ctx_s { int n; } *Ctx;

static VALUE
ct_get(VALUE self, VALUE x)
{
    Ctx c = (Ctx)x;
    return c ? Qtrue : Qfalse;
}

void
Init_api_cptr_typedef(void)
{
    VALUE m = rb_define_module("CptrTypedef");
    rb_define_module_function(m, "get", ct_get, 1);
}
