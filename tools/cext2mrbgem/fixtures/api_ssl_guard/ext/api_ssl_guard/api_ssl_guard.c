#include <ruby.h>

static VALUE
sg_plain(VALUE self)
{
    return Qnil;
}

#ifdef HAVE_OPENSSL_BIO_H
static VALUE
sg_ssl(VALUE self)
{
    return Qnil;
}
#endif

#if 0 == 1
static VALUE
sg_dead(VALUE self)
{
    return Qnil;
}
#endif

void
Init_api_ssl_guard(void)
{
    VALUE c = rb_define_class("SslGuard", rb_cObject);
    rb_define_method(c, "plain", sg_plain, 0);
#ifdef HAVE_OPENSSL_BIO_H
    rb_define_method(c, "ssl", sg_ssl, 0);
#endif
#if 0 == 1
    rb_define_method(c, "dead", sg_dead, 0);
#endif
}
