#include <ruby.h>
#include <ruby/st.h>

/* st_table with number keys (st_init_numtable): insert, lookup, delete, iterate with a callback that takes no mruby state */
static st_table *table;

static int sum_cb(st_data_t key, st_data_t value, st_data_t arg)
{
    *(st_data_t *)arg += value;
    return ST_CONTINUE;
}

static VALUE m_put(VALUE self, VALUE k, VALUE v)
{
    st_insert(table, (st_data_t)NUM2LONG(k), (st_data_t)NUM2LONG(v));
    return Qnil;
}

static VALUE m_get(VALUE self, VALUE k)
{
    st_data_t v = 0;
    if (st_lookup(table, (st_data_t)NUM2LONG(k), &v)) return LONG2NUM((long)v);
    return Qnil;
}

static VALUE m_del(VALUE self, VALUE k)
{
    st_data_t key = (st_data_t)NUM2LONG(k), val = 0;
    return st_delete(table, &key, &val) ? LONG2NUM((long)val) : Qnil;
}

static VALUE m_sum(VALUE self)
{
    st_data_t total = 0;
    st_foreach(table, sum_cb, (st_data_t)&total);
    return LONG2NUM((long)total);
}

static VALUE m_size(VALUE self)
{
    return LONG2NUM((long)table->num_entries);
}

void Init_api_st_numtable(void)
{
    VALUE mod = rb_define_module("ApiStNum");
    table = st_init_numtable_with_size(128);
    rb_define_module_function(mod, "put", m_put, 2);
    rb_define_module_function(mod, "get", m_get, 1);
    rb_define_module_function(mod, "del", m_del, 1);
    rb_define_module_function(mod, "sum", m_sum, 0);
    rb_define_module_function(mod, "size", m_size, 0);
    st_free_table(table);
    table = st_init_numtable();
}
