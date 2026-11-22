#include <ruby.h>

/* rb_marshal_load(port): an object read from a marshalled string. */
static VALUE
ml_load(VALUE self, VALUE data)
{
    return rb_marshal_load(data);
}

void
Init_api_marshal_load(void)
{
    VALUE m = rb_define_module("MarshalLoad");
    rb_define_module_function(m, "load", ml_load, 1);
}
