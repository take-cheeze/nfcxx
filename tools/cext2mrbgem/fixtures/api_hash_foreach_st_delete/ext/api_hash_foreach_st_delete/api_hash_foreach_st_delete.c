#include <ruby.h>
#include <ruby/st.h>

/* control: a rb_hash_foreach callback that returns ST_DELETE (an st_foreach value) is refused: mrb_hash_foreach would stop there */
static int drop_cb(VALUE key, VALUE val, VALUE arg)
{
    return ST_DELETE;
}

static VALUE m_drop(VALUE self, VALUE h)
{
    rb_hash_foreach(h, drop_cb, Qnil);
    return Qnil;
}

void Init_api_hash_foreach_st_delete(void)
{
    VALUE mod = rb_define_module("ApiHfStDelete");
    rb_define_module_function(mod, "drop", m_drop, 1);
}
