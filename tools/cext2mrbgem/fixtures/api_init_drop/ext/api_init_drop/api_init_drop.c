#include <ruby.h>

/* a refused statement in Init (a copy of an array: the fork has no mrb_ary_dup): it is dropped as a no-op, and the gem loads */
void
Init_api_init_drop(void)
{
    VALUE c = rb_define_class("InitDrop", rb_cObject);
    rb_ary_dup(Qnil);
}
