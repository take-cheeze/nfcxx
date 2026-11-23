#include <ruby.h>

/* rb_protect with a VALUE array as its data ((VALUE)args): the callback reads the array, and an element is a struct pointer. */
struct pa_state { long n; };

static VALUE
pa_cb(VALUE pointer)
{
    VALUE *args = (VALUE *)pointer;
    struct pa_state *st = (struct pa_state *)args[0];
    st->n++;
    return Qnil;
}

static VALUE
pa_run(VALUE self)
{
    struct pa_state s;
    VALUE args[2];
    int state = 0;
    s.n = 0;
    args[0] = (VALUE)&s;
    args[1] = Qnil;
    rb_protect(pa_cb, (VALUE)args, &state);
    return LONG2NUM(s.n);
}

void
Init_api_protect_array(void)
{
    VALUE m = rb_define_module("ProtectArray");
    rb_define_module_function(m, "run", pa_run, 0);
}
