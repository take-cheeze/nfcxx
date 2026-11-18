#include <ruby.h>

struct holder {
    VALUE value;
};

union cell {
    void *child;
    long  value;
};

static VALUE m_cells(VALUE self)
{
    struct holder h;
    union cell    c;

    c.value = 0;
    h.value = Qnil;
    return h.value;
}

void Init_api_union_field(void)
{
    rb_define_method(rb_cObject, "cells", m_cells, 0);
}
