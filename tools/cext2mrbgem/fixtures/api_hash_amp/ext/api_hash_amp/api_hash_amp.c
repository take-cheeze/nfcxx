#include <ruby.h>

struct holder { VALUE hash; };

/* the callback of rb_hash_foreach, given by address (&cb) with the hash held in a struct field */
static int
cb_count(VALUE key, VALUE val, VALUE payload)
{
    VALUE *count = (VALUE *)payload;
    *count = INT2FIX(FIX2INT(*count) + 1);
    return ST_CONTINUE;
}

static VALUE
m_count(VALUE self)
{
    struct holder *h = (struct holder *)DATA_PTR(self);
    VALUE count = INT2FIX(0);
    rb_hash_foreach(h->hash, &cb_count, (VALUE)&count);
    return count;
}

void
Init_api_hash_amp(void)
{
    VALUE c = rb_define_class("HashAmp", rb_cObject);
    rb_define_method(c, "count", m_count, 0);
}
