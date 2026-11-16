#include <ruby.h>

/* the body calls the proc it is given; only TypeError and EOFError (and their subclasses) are rescued */
static VALUE
rs2_body(VALUE proc)
{
    return rb_funcall(proc, rb_intern("call"), 0);
}

static VALUE
rs2_recover(VALUE data, VALUE exc)
{
    return rb_str_new_cstr("rescued");
}

static VALUE
m_safe2(VALUE self, VALUE proc)
{
    return rb_rescue2(rs2_body, proc, rs2_recover, self, rb_eTypeError, rb_eEOFError, (VALUE)0);
}

void
Init_api_rescue2(void)
{
    VALUE c = rb_define_class("RescueApi2", rb_cObject);
    rb_define_method(c, "safe2", m_safe2, 1);
}
