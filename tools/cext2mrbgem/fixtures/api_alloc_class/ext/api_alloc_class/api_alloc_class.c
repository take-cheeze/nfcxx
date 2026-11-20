#include <ruby.h>

/* a class with its own allocator: the struct is allocated with the object, and a helper the allocator reaches is plain */
typedef struct {
    int n;
} ac_counter;

static void
ac_free(void *p)
{
    xfree(p);
}

static VALUE
ac_init_counter(VALUE self)
{
    ac_counter *c;
    Data_Get_Struct(self, ac_counter, c);
    c->n = 0;
    return self;
}

static VALUE
ac_alloc(VALUE klass)
{
    ac_counter *c;
    VALUE obj = Data_Make_Struct(klass, ac_counter, NULL, ac_free, c);
    c->n = 100;
    return obj;
}

static VALUE
ac_inc(VALUE self)
{
    ac_counter *c;
    Data_Get_Struct(self, ac_counter, c);
    return INT2NUM(++c->n);
}

void
Init_api_alloc_class(void)
{
    VALUE k = rb_define_class("AllocCounter", rb_cObject);
    rb_define_alloc_func(k, ac_alloc);
    rb_define_method(k, "initialize", ac_init_counter, 0);
    rb_define_method(k, "inc", ac_inc, 0);
}
