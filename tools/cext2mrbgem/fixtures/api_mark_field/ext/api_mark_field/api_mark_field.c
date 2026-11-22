#include <ruby.h>

/* A mark function stored in a struct's mark field and called through it by the data type's mark (oj's parser shape). */
struct hold {
    VALUE v;
    void (*mark)(struct hold *);
};

static void
hold_mark(struct hold *h)
{
    rb_gc_mark(h->v);
}

static void
hold_dmark(void *ptr)
{
    struct hold *h = (struct hold *)ptr;
    h->mark(h);
}

static VALUE
hold_set(VALUE self, VALUE v)
{
    struct hold h;
    h.v = v;
    h.mark = hold_mark;
    hold_dmark(&h);
    return v;
}

void
Init_api_mark_field(void)
{
    VALUE m = rb_define_module("MarkField");
    rb_define_module_function(m, "set", hold_set, 1);
}
