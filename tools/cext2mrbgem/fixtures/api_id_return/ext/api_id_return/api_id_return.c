#include <ruby.h>

/* a helper returning an ID, with a VALUE-returning call returned where the ID is wanted (mrb_symbol of its result) */
static ID
helper_id(VALUE name)
{
    return rb_funcall(name, rb_intern("to_sym"), 0);
}

/* an ID returned where a VALUE is returned: CRuby's ID is returned as the value (mrb_symbol_value in the fork) */
static VALUE
m_id_value(VALUE self, VALUE name)
{
    ID id = helper_id(name);
    return id;
}

void
Init_api_id_return(void)
{
    VALUE c = rb_define_class("IdReturn", rb_cObject);
    rb_define_method(c, "id_value", m_id_value, 1);
}
