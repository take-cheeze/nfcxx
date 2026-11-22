#include <ruby.h>

/* t is a long in one block and a VALUE in another: each use is the innermost declaration's type, so the (long)t cast is an
   integer use (no VALUE-as-integer refusal) and the VALUE t is an object. */
static VALUE
bs_run(VALUE self, VALUE x)
{
    {
        long t = 4;
        long u = (long)t;
        if (u) return x;
    }
    {
        VALUE t = x;
        return t;
    }
}

void
Init_api_block_shadow(void)
{
    VALUE m = rb_define_module("BlockShadow");
    rb_define_module_function(m, "run", bs_run, 1);
}
