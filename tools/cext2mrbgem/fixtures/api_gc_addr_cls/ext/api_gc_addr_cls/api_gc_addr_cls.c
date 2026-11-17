#include <ruby.h>

static VALUE err_class;

static VALUE m_err(VALUE self)
{
    return err_class;
}

void Init_api_gc_addr_cls(void)
{
    VALUE mod = rb_define_module("ApiGcAddrCls");
    err_class = rb_define_class_under(mod, "Failed", rb_eStandardError);
    rb_gc_register_address(&err_class);
    rb_define_module_function(mod, "err", m_err, 0);
}
