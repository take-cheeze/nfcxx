#include <ruby.h>

/* the body calls the proc it is given; the rescue callback gets the exception as its second argument */
static VALUE
rs_body(VALUE proc)
{
    return rb_funcall(proc, rb_intern("call"), 0);
}

static VALUE
rs_recover(VALUE data, VALUE exc)
{
    return rb_str_new_cstr("rescued");
}

static VALUE
m_safe(VALUE self, VALUE proc)
{
    return rb_rescue(rs_body, proc, rs_recover, self);
}

void
Init_api_rescue(void)
{
    VALUE c = rb_define_class("RescueApi", rb_cObject);
    rb_define_method(c, "safe", m_safe, 1);
}
