#include <ruby.h>
#include <ruby/st.h>

/* st_foreach whose callback returns ST_DELETE, ST_CHECK and ST_STOP; the callback takes no mruby state */
static int drop_negative(st_data_t key, st_data_t value, st_data_t arg)
{
    if ((long)value < 0) return ST_DELETE;
    if ((long)value == 0) return ST_CHECK;
    if ((long)value > 100) return ST_STOP;
    return ST_CONTINUE;
}

static VALUE m_prune(VALUE self, VALUE h)
{
    st_table *t = st_init_numtable();
    st_data_t i;
    for (i = 0; i < 5; i++) st_insert(t, i, (st_data_t)((long)i - 2));
    st_foreach(t, drop_negative, (st_data_t)0);
    st_free_table(t);
    return Qnil;
}

void Init_api_st_foreach_delete(void)
{
    VALUE mod = rb_define_module("ApiStForeach");
    rb_define_module_function(mod, "prune", m_prune, 1);
}
