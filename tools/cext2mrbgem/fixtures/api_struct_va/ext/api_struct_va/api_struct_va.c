#include <ruby.h>

/* a CRuby Struct: the class is defined with its members, and an instance is built with its values */
static VALUE sv_point;

static VALUE
sv_make(VALUE self, VALUE x, VALUE y)
{
    return rb_struct_new(sv_point, x, y);
}

void
Init_api_struct_va(void)
{
    VALUE m = rb_define_module("StructVa");
    sv_point = rb_struct_define("SvPoint", "x", "y", NULL);
    rb_define_module_function(m, "make", sv_make, 2);
}
