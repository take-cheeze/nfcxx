#include <ruby.h>

/* the work run without the GVL (CRuby): with --thread-sync the call is a direct call on the calling thread */
static void *
work(void *data)
{
    return data;
}

static VALUE
m_run(VALUE self, VALUE v)
{
    void *r = rb_thread_call_without_gvl(work, (void *)v, RUBY_UBF_IO, NULL);
    return (VALUE)r;
}

void
Init_api_thread_sync(void)
{
    VALUE c = rb_define_class("ThreadSync", rb_cObject);
    rb_define_method(c, "run", m_run, 1);
}
