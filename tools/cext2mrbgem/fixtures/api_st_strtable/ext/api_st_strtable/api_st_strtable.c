#include <ruby.h>
#include <ruby/st.h>

/* st_table with string keys (st_init_strtable): the keys are C strings compared by content */
static st_table *names;

static VALUE m_add(VALUE self, VALUE key)
{
    char *copy = strdup(StringValueCStr(key));
    st_add_direct(names, (st_data_t)copy, (st_data_t)1);
    return Qtrue;
}

static VALUE m_count(VALUE self, VALUE key)
{
    st_data_t v = 0;
    if (st_lookup(names, (st_data_t)StringValueCStr(key), &v)) return INT2NUM((int)v);
    return INT2NUM(0);
}

static VALUE m_entries(VALUE self)
{
    return INT2NUM((int)names->num_entries);
}

void Init_api_st_strtable(void)
{
    VALUE mod = rb_define_module("ApiStStr");
    names = st_init_strtable();
    rb_define_module_function(mod, "add", m_add, 1);
    rb_define_module_function(mod, "count", m_count, 1);
    rb_define_module_function(mod, "entries", m_entries, 0);
}
