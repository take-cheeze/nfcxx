#include <ruby.h>

/* a struct field of CRuby's encoding pointer type: the fork has no Encoding, so the type is a placeholder for declarations
   (its uses are refused, and the functions holding them are stubs) */
struct enc_holder {
    rb_encoding *enc;
    int n;
};

static VALUE
m_count(VALUE self)
{
    struct enc_holder h;
    h.n = 1;
    return INT2FIX(h.n);
}

void
Init_api_rb_encoding_field(void)
{
    VALUE c = rb_define_class("EncField", rb_cObject);
    rb_define_method(c, "count", m_count, 0);
}
