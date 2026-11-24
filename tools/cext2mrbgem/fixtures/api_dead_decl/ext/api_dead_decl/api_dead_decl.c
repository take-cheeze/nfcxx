#include <ruby.h>

/* A VALUE jd declared in a dead #if 0 branch is not a file-scope name: the int jd parameter below is an int. */
#if 0
static VALUE
dd_old(VALUE self)
{
    VALUE jd = self;
    return jd;
}
#endif

static int
dd_twice(int jd)
{
    return jd * 2;
}

static VALUE
dd_run(VALUE self, VALUE x)
{
    int jd = 4;
    return INT2FIX(dd_twice(jd));
}

void
Init_api_dead_decl(void)
{
    VALUE m = rb_define_module("DeadDecl");
    rb_define_module_function(m, "run", dd_run, 1);
}
