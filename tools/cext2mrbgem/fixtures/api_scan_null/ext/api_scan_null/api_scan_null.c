#include <ruby.h>

static VALUE m_opt(int argc, VALUE *argv, VALUE self)
{
    VALUE ropts;
    rb_scan_args(argc, argv, "11", NULL, &ropts);
    return ropts;
}

void Init_api_scan_null(void)
{
    rb_define_method(rb_cObject, "opt_arg", m_opt, -1);
}
