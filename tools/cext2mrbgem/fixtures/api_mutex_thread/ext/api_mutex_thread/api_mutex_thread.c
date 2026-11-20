#include <ruby.h>

/* a mutex around a critical section, and the current thread: one thread in mruby, so the lock never contends */
static VALUE
mt_guarded(VALUE self, VALUE v)
{
    VALUE mu = rb_mutex_new();
    rb_mutex_lock(mu);
    rb_mutex_unlock(mu);
    rb_thread_current();
    return v;
}

void
Init_api_mutex_thread(void)
{
    VALUE m = rb_define_module("MutexThread");
    rb_define_module_function(m, "guarded", mt_guarded, 1);
}
