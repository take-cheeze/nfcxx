#include <ruby.h>

struct ctx { int count; };

static int count_cb(VALUE key, VALUE value, VALUE ptr)
{
    struct ctx *c = (struct ctx *)ptr;
    c->count++;
    return ST_CONTINUE;
}

static VALUE m_count(VALUE self, VALUE h)
{
    struct ctx c = {0};
    struct ctx *p = &c;
    rb_hash_foreach(h, count_cb, (VALUE)p);
    return INT2NUM(c.count);
}

static VALUE m_count2(VALUE self, VALUE h)
{
    struct ctx c = {0};
    struct ctx *p = &c;
    rb_hash_foreach(h, count_cb, (VALUE)p);
    return INT2NUM(c.count);
}

void Init_api_hash_ptr_stuck(void)
{
    rb_define_method(rb_cObject, "count_pairs", m_count, 1);
    rb_define_method(rb_cObject, "count_pairs2", m_count2, 1);
}
