#include <ruby.h>

/* a struct of callbacks filled by a positional initializer at file scope (struct TAG var = { h1, h2 };): the member index
 * of each helper gives its field; the calls through the field (ops->NAME(...)) are in a registered method */
struct fp_ops {
    VALUE (*on_first)(VALUE v);
    int marker;
    VALUE (*on_second)(VALUE v);
};

static VALUE fp_first(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

static VALUE fp_second(VALUE v) {
    return Qtrue;
}

static struct fp_ops fp_table = { fp_first, 0, fp_second };

static VALUE fp_run(VALUE self, VALUE v) {
    struct fp_ops *ops = &fp_table;
    return ops->on_second(ops->on_first(v));
}

void Init_api_fnptr_positional(void) {
    VALUE m = rb_define_module("FnptrPositional");
    rb_define_module_function(m, "run", fp_run, 1);
}
