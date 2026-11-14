#include <ruby.h>

struct afp_parser {
    VALUE held;
    void (*on_value)(struct afp_parser *p, VALUE v);
};

static void afp_store(struct afp_parser *p, VALUE v) {
    rb_ary_push(p->held, v);
}

static VALUE afp_run(VALUE self, VALUE v) {
    struct afp_parser p;
    p.held = rb_ary_new();
    p.on_value = afp_store;
    p.on_value(&p, v);
    return p.held;
}

void Init_api_fnptr_field(void) {
    VALUE m = rb_define_module("AFP");
    rb_define_module_function(m, "run", afp_run, 1);
}
