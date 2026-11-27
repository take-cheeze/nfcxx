#include <ruby.h>
#include <ruby/st.h>

/* control: the st_foreach callback builds a Ruby value, so it needs the mruby state: the converter still refuses it */
static int collect_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    rb_ary_push((VALUE)arg, LONG2NUM((long)key));
    return ST_CONTINUE;
}

static VALUE m_keys(VALUE self, VALUE h)
{
    st_table *t = st_init_numtable();
    VALUE out = rb_ary_new();
    st_insert(t, 1, 2);
    st_foreach(t, collect_cb, (st_data_t)out);
    st_free_table(t);
    return out;
}

void Init_api_st_foreach_mrb(void)
{
    VALUE mod = rb_define_module("ApiStForeachMrb");
    rb_define_module_function(mod, "keys", m_keys, 1);
}
