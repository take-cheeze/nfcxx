#include <ruby.h>

/* Object-like aliases of rb_gc_mark: rb_gc_mark_movable (a mapped mark call, so its alias is dead and dropped) and mark_second (not
   an API name, so it becomes a function-like mark macro). Both are used only in the data type's mark callback. */
struct pair {
    VALUE a;
    VALUE b;
};

#define rb_gc_mark_movable rb_gc_mark
#define mark_second rb_gc_mark

static void
pair_mark(void *ptr)
{
    struct pair *p = (struct pair *)ptr;
    rb_gc_mark_movable(p->a);
    mark_second(p->b);
}

static void
pair_free(void *ptr)
{
    xfree(ptr);
}

static const rb_data_type_t pair_type = { "pair", { pair_mark, pair_free, 0 }, 0, 0, 0 };

static VALUE
pair_hold(VALUE self, VALUE a, VALUE b)
{
    struct pair *p = ALLOC(struct pair);
    p->a = a;
    p->b = b;
    return TypedData_Wrap_Struct(rb_cObject, &pair_type, p);
}

void
Init_api_gc_alias(void)
{
    VALUE m = rb_define_module("GcAlias");
    rb_define_module_function(m, "hold", pair_hold, 2);
}
