#include <ruby.h>

/* an OpenSSL-only source, excluded by --exclude: its refusal must not reach the output */
static VALUE
extra_only(VALUE self)
{
    rb_thread_current();
    return Qnil;
}
