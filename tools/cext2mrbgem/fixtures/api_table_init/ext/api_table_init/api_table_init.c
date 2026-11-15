#include <ruby.h>

/* a helper that needs the state, reached through a file-scope table (its address is in the initializer) */
static VALUE
ti_str(VALUE self)
{
    return rb_str_new_cstr("table");
}

struct ti_entry {
    const char *name;
    VALUE (*fn)(VALUE self);
};

static struct ti_entry ti_table[] = {
    {"str", ti_str},
};

static VALUE
ti_run(VALUE self, int i)
{
    return ti_table[i].fn(self);
}

static VALUE
m_run(VALUE self, VALUE i)
{
    return ti_run(self, NUM2INT(i));
}

void
Init_api_table_init(void)
{
    VALUE c = rb_define_class("TableInit", rb_cObject);
    rb_define_method(c, "run", m_run, 1);
}
