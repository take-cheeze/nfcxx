#include <ruby.h>

struct hold {
    const char *data;
    long size;
    void *enc;
};

static struct hold H = {"ab", 2, NULL};

static VALUE m_str(VALUE self)
{
    return rb_enc_str_new(H.data, H.size, H.enc);
}

void Init_api_enc_member(void)
{
    rb_define_method(rb_cObject, "hold_str", m_str, 0);
}
