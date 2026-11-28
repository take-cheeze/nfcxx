#include <ruby.h>
struct RescueArg { VALUE proc; };
static VALUE
rc_body(VALUE a)
{
    struct RescueArg *arg = (struct RescueArg *)a;
    return rb_funcall(arg->proc, rb_intern("call"), 0);
}

/* the rescue callback checks the exception's class itself: a TypeError is rescued, any other exception is re-raised by the wrapper */
static VALUE
rc_recover(VALUE a, VALUE exc)
{
    (void)a;
    if (rb_obj_is_kind_of(exc, rb_eTypeError))
        return rb_str_new_cstr("type error");
    return Qnil;
}

static VALUE
m_rc(VALUE self, VALUE proc)
{
    struct RescueArg arg;
    arg.proc = proc;
    return rb_rescue(rc_body, (VALUE)&arg, rc_recover, Qnil);
}

void
Init_api_rescue_class(void)
{
    VALUE c = rb_define_class("RescueClass", rb_cObject);
    rb_define_method(c, "safe", m_rc, 1);
}
