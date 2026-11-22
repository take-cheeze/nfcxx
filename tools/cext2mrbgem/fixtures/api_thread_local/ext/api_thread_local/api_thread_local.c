#include <ruby.h>

/* CRuby's thread-local storage of a symbol key (BigDecimal's exception mode): per state in the fork. */
static ID id_mode;

static VALUE
tl_set(VALUE self, VALUE v)
{
    rb_thread_local_aset(rb_thread_current(), id_mode, v);
    return v;
}

static VALUE
tl_get(VALUE self)
{
    return rb_thread_local_aref(rb_thread_current(), id_mode);
}

void
Init_api_thread_local(void)
{
    VALUE m = rb_define_module("ThreadLocal");
    id_mode = rb_intern("exception_mode");
    rb_define_module_function(m, "set", tl_set, 1);
    rb_define_module_function(m, "get", tl_get, 0);
}
