#include <ruby.h>

/* rb_ensure with a pointer carried in the data VALUE ((VALUE)p, a pointer local): the callbacks cast it back. */
struct ep_state { long n; };

static VALUE
ep_body(VALUE a)
{
    struct ep_state *st = (struct ep_state *)a;
    st->n++;
    return Qnil;
}

static VALUE
ep_done(VALUE a)
{
    struct ep_state *st = (struct ep_state *)a;
    st->n--;
    return Qnil;
}

static VALUE
ep_run(VALUE self)
{
    struct ep_state s;
    struct ep_state *p = &s;
    s.n = 0;
    rb_ensure(ep_body, (VALUE)p, ep_done, (VALUE)p);
    return LONG2NUM(s.n);
}

void
Init_api_ensure_pdata(void)
{
    VALUE m = rb_define_module("EnsurePdata");
    rb_define_module_function(m, "run", ep_run, 0);
}
