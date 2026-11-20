#include <ruby.h>

/* == and != between VALUEs are identity: the same object or the same immediate */
static VALUE
vi_same(VALUE self, VALUE a, VALUE b)
{
    return (a == b) ? Qtrue : Qfalse;
}

static VALUE
vi_is_ordinal(VALUE self, VALUE k)
{
    return (k == ID2SYM(rb_intern("ordinal"))) ? Qtrue : Qfalse;
}

static VALUE
vi_not_nil(VALUE self, VALUE a)
{
    return (a != Qnil) ? Qtrue : Qfalse;
}

void
Init_api_value_identity(void)
{
    VALUE m = rb_define_module("ValueIdentity");
    rb_define_module_function(m, "same", vi_same, 2);
    rb_define_module_function(m, "not_nil", vi_not_nil, 1);
    rb_define_module_function(m, "ordinal", vi_is_ordinal, 1);
}
