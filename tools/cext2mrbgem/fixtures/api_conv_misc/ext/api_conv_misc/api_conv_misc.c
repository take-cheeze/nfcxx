#include <ruby.h>

/* a number parsed from a C string, with badcheck; a value with a to_str conversion, or nil */
static VALUE
m_dbl(VALUE self, VALUE str)
{
    return DBL2NUM(rb_cstr_to_dbl(RSTRING_PTR(str), 1));
}

static VALUE
m_to_str(VALUE self, VALUE val)
{
    return rb_check_convert_type(val, T_STRING, "String", "to_str");
}

/* yields to the block, or raises LocalJumpError when there is none */
static VALUE
m_each_twice(VALUE self)
{
    rb_need_block();
    rb_yield(INT2FIX(1));
    return rb_yield(INT2FIX(2));
}

/* the GC switch: each call returns whether GC was disabled before it */
static VALUE
m_gc_off(VALUE self)
{
    return rb_gc_disable();
}

static VALUE
m_gc_on(VALUE self)
{
    return rb_gc_enable();
}

/* a fatal error: the process ends, and no rescue sees it */
static VALUE
m_fatal(VALUE self)
{
    rb_fatal("boom %d", 1);
    return Qnil;
}

/* a global function: a private method of Kernel */
static VALUE
m_global(VALUE self)
{
    return INT2FIX(7);
}

void
Init_api_conv_misc(void)
{
    VALUE c = rb_define_class("ConvMisc", rb_cObject);
    rb_define_method(c, "dbl", m_dbl, 1);
    rb_define_method(c, "to_str", m_to_str, 1);
    rb_define_method(c, "each_twice", m_each_twice, 0);
    rb_define_method(c, "gc_off", m_gc_off, 0);
    rb_define_method(c, "gc_on", m_gc_on, 0);
    rb_define_method(c, "fatal", m_fatal, 0);
    rb_define_global_function("conv_global", m_global, 0);
}
