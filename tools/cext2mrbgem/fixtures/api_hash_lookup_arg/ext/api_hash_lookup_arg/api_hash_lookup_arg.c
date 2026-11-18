#include <ruby.h>

static VALUE m_flag(VALUE self, VALUE hash)
{
    if (rb_hash_lookup(hash, ID2SYM(rb_intern("lax"))) == Qtrue) {
        return Qtrue;
    }
    return Qfalse;
}

void Init_api_hash_lookup_arg(void)
{
    rb_define_method(rb_cObject, "lax_flag", m_flag, 1);
}
