#include <ruby.h>

/* a refused statement in Init (a thread-local store: the fork has no Thread): it is dropped as a no-op, and the gem loads */
void
Init_api_init_drop(void)
{
    VALUE c = rb_define_class("InitDrop", rb_cObject);
    rb_thread_local_aset(rb_thread_current(), rb_intern("api_init_drop"), Qnil);
}
