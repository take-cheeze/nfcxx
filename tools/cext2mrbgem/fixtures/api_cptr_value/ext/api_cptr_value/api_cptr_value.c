#include <ruby.h>

/* A pointer carried in a VALUE (CRuby passes a struct pointer as a VALUE): read with a cast back, and stored by casting to VALUE. */
typedef struct { int n; } Holder;

static VALUE
cp_store(VALUE self, VALUE x)
{
    Holder *h = (Holder *)x;
    VALUE v = (VALUE)h;
    return v;
}

void
Init_api_cptr_value(void)
{
    VALUE m = rb_define_module("CptrValue");
    rb_define_module_function(m, "store", cp_store, 1);
}
