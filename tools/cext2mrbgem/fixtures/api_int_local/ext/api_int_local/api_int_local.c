#include <ruby.h>

/* A VALUE local that CRuby uses only as a C integer: its word is the integer. The fork's VALUE is a struct, so jd and t are
   mrb_int locals; x is an object and stays a VALUE. */
static int
il_twice(int n)
{
    return n * 2;
}

static VALUE
il_int(VALUE self, VALUE x)
{
    VALUE jd = 5;
    VALUE t;
    t = il_twice(jd);
    t = il_twice((int)t);
    if (!t) return x;
    return x;
}

static VALUE
il_obj(VALUE self, VALUE x)
{
    VALUE keep = x;
    return keep;
}

void
Init_api_int_local(void)
{
    VALUE m = rb_define_module("IntLocal");
    rb_define_module_function(m, "int", il_int, 1);
    rb_define_module_function(m, "obj", il_obj, 1);
}
