#include <ruby.h>

/* A temporary buffer assigned from RB_ALLOCV_N (CRuby's ALLOCV_N: a pointer declared earlier, then assigned), freed by RB_ALLOCV_END. */
static VALUE
av_sum(VALUE self, VALUE str)
{
    VALUE vbuf;
    char *buf;
    long n = 4;

    buf = RB_ALLOCV_N(char, vbuf, n + 1);
    buf[0] = 'x';
    buf[n] = '\0';
    RB_ALLOCV_END(vbuf);
    return str;
}

void
Init_api_allocv_assign(void)
{
    VALUE m = rb_define_module("AllocvAssign");
    rb_define_module_function(m, "sum", av_sum, 1);
}
