#include <ruby.h>

/* a VALUE passed as an sid_t key (oj's cache is keyed by the object's identity): its word is the key */
typedef unsigned long long sid_t;

static int
sk_lookup(sid_t key)
{
    return key != 0;
}

static VALUE
sk_has(VALUE self, VALUE obj)
{
    return sk_lookup(obj) ? Qtrue : Qfalse;
}

void
Init_api_sid_key(void)
{
    VALUE m = rb_define_module("SidKey");
    rb_define_module_function(m, "has?", sk_has, 1);
}
