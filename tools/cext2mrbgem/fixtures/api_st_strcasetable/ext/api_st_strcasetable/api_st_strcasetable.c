#include <ruby.h>
#include <ruby/st.h>

/* st_table with case-insensitive string keys (st_init_strcasetable), and the st_strcasecmp family the gems use */
static st_table *headers;

static VALUE m_put(VALUE self, VALUE key, VALUE value)
{
    st_insert(headers, (st_data_t)StringValueCStr(key), (st_data_t)StringValueCStr(value));
    return Qnil;
}

static VALUE m_has(VALUE self, VALUE key)
{
    return st_lookup(headers, (st_data_t)StringValueCStr(key), NULL) ? Qtrue : Qfalse;
}

static VALUE m_same(VALUE self, VALUE a, VALUE b)
{
    return st_strcasecmp(StringValueCStr(a), StringValueCStr(b)) == 0 ? Qtrue : Qfalse;
}

static VALUE m_prefix(VALUE self, VALUE a, VALUE prefix)
{
    return st_strncasecmp(StringValueCStr(a), StringValueCStr(prefix), 3) == 0 ? Qtrue : Qfalse;
}

void Init_api_st_strcasetable(void)
{
    VALUE mod = rb_define_module("ApiStCase");
    headers = st_init_strcasetable_with_size(16);
    rb_define_module_function(mod, "put", m_put, 2);
    rb_define_module_function(mod, "has", m_has, 1);
    rb_define_module_function(mod, "same", m_same, 2);
    rb_define_module_function(mod, "prefix", m_prefix, 2);
}
