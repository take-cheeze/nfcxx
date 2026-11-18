#include <ruby.h>
#include <ruby/st.h>

static int count_all(VALUE key, VALUE value, VALUE data)
{
    return ST_CONTINUE;
}

static VALUE m_walk(VALUE self, VALUE h)
{
    rb_hash_foreach(h, count_all, Qnil);
    return Qtrue;
}

void Init_api_st_include(void)
{
    rb_define_method(rb_cObject, "walk_hash", m_walk, 1);
}
