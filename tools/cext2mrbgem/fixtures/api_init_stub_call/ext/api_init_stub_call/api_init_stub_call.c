#include <ruby.h>

/* a function whose body uses a refused API (a thread-local store: the fork has no Thread) is stubbed; Init calls it, and the call
 * is dropped in Init (the stub would raise at load, aborting the gem), noted in REFUSALS.txt. outer is not refused, but it calls the
 * stub, so Init's call to outer is dropped too (the closure of the callers of stubs). */
static VALUE
helper(VALUE self)
{
    rb_thread_local_aset(rb_thread_current(), rb_intern("api_init_stub_call"), self);
    return self;
}

static VALUE
outer(VALUE self)
{
    return helper(self);
}

void
Init_api_init_stub_call(void)
{
    VALUE c = rb_define_class("InitStubCall", rb_cObject);
    helper(c);
    outer(c);
}
