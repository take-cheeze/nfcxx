#include <ruby.h>

/* a static helper defined in two files, used as a value (assigned to a field, followed by ';'): the use is renamed too */
static VALUE sv_dup(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

struct sv_ops { VALUE (*fn)(VALUE); };
static struct sv_ops sv_table;

static VALUE sv_run(VALUE self, VALUE v) {
    sv_table.fn = sv_dup;
    return sv_table.fn(v);
}

void Init_api_static_value(void) {
    VALUE m = rb_define_module("StaticValue");
    rb_define_module_function(m, "run", sv_run, 1);
}
