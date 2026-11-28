#include <ruby.h>
struct RescueArg { VALUE proc; };
static VALUE
rn_body(VALUE a)
{
    struct RescueArg *arg = (struct RescueArg *)a;
    return rb_funcall(arg->proc, rb_intern("call"), 0);
}

/* the rescue callback does not test the class: a pointer-data rb_rescue is refused (CRuby catches only StandardError) */
static VALUE
rn_recover(VALUE a, VALUE exc)
{
    (void)a;
    (void)exc;
    return Qnil;
}

static VALUE
m_rn(VALUE self, VALUE proc)
{
    struct RescueArg arg;
    arg.proc = proc;
    return rb_rescue(rn_body, (VALUE)&arg, rn_recover, Qnil);
}

void
Init_api_rescue_nocheck(void)
{
    VALUE c = rb_define_class("RescueNocheck", rb_cObject);
    rb_define_method(c, "safe", m_rn, 1);
}
