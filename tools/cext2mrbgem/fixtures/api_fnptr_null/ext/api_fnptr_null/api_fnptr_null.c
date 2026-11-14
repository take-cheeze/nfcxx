#include <ruby.h>

/* a positional table of callbacks where one entry is NULL (no callback), and a callback stored by address (x.NAME = &helper;)
 * in a registered method: both are read by the field rule */
struct fn_ops {
    VALUE (*first)(VALUE v);
    VALUE (*second)(VALUE v);
    void (*store)(VALUE v);
};

static VALUE fn_first(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

static void fn_store(VALUE v) {
    (void)v;
}

static struct fn_ops fn_table = { fn_first, NULL, NULL };

static VALUE fn_run(VALUE self, VALUE v) {
    struct fn_ops *ops = &fn_table;
    ops->store = &fn_store;
    return ops->first(v);
}

void Init_api_fnptr_null(void) {
    VALUE m = rb_define_module("FnptrNull");
    rb_define_module_function(m, "run", fn_run, 1);
}
