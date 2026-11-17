#include <ruby.h>

static int walk(VALUE key, VALUE value, VALUE proc)
{
    if (Qnil == proc) {
        return ST_CONTINUE;
    }
    if (RB_TYPE_P(value, T_HASH)) {
        rb_hash_foreach(value, walk, proc);
    }
    return ST_CONTINUE;
}

static VALUE m_walk(VALUE self, VALUE h, VALUE proc)
{
    rb_hash_foreach(h, walk, proc);
    walk(Qnil, h, Qnil);
    return Qtrue;
}

void Init_api_hash_value_data(void)
{
    rb_define_method(rb_cObject, "walk_all", m_walk, 2);
}
