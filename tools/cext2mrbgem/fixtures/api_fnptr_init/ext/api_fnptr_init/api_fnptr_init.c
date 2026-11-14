#include <ruby.h>

/* a table of option handlers: each entry's func is a designated initializer (.func = handler) at file scope; the calls
 * go through op->func(...) inside a method, so the field and its handlers take the mruby state */
struct fi_opt {
    const char *name;
    VALUE (*func)(VALUE self, VALUE value);
};

static VALUE fi_on(VALUE self, VALUE value) {
    if (NIL_P(value)) rb_raise(rb_eArgError, "nil");
    return Qtrue;
}

static VALUE fi_off(VALUE self, VALUE value) {
    return Qfalse;
}

static struct fi_opt fi_opts[] = {
    {.name = "on", .func = fi_on},
    {.name = "off", .func = fi_off},
};

static VALUE fi_set(VALUE self, VALUE name, VALUE value) {
    int i;
    for (i = 0; i < 2; i++) {
        struct fi_opt *op = &fi_opts[i];
        return op->func(self, value);
    }
    return Qnil;
}

void Init_api_fnptr_init(void) {
    VALUE m = rb_define_module("FnptrInit");
    rb_define_module_function(m, "set", fi_set, 2);
}
