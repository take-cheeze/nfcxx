#include <ruby.h>

/* a struct member whose type is a typedef'd function pointer, filled by a positional table of structs at file scope
 * (struct tt_code codes[] = { {name, handler}, ... }); the calls through the member are in a registered method */
typedef VALUE (*TTFunc)(VALUE v);

struct tt_code {
    const char *name;
    TTFunc      handler;
};

static VALUE tt_first(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

static VALUE tt_second(VALUE v) {
    return Qtrue;
}

static struct tt_code tt_codes[] = {
    {"first", tt_first},
    {"second", tt_second},
};

static VALUE tt_run(VALUE self, VALUE v) {
    return tt_codes[0].handler(v);
}

void Init_api_typed_table(void) {
    VALUE m = rb_define_module("TypedTable");
    rb_define_module_function(m, "run", tt_run, 1);
}
