#include <ruby.h>

typedef void (*atb_dump_fn)(VALUE obj, int depth);

static void atb_dump_nil(VALUE obj, int depth) {
    rb_ary_push(rb_ary_new(), obj);
}

static void atb_dump_str(VALUE obj, int depth) {
    rb_str_new_cstr("x");
}

static atb_dump_fn atb_table[] = { atb_dump_nil, atb_dump_str };

static VALUE atb_run(VALUE self, VALUE v) {
    atb_table[0](v, 0);
    atb_table[1](v, 0);
    return Qnil;
}

void Init_api_fnptr_table(void) {
    VALUE m = rb_define_module("ATB");
    rb_define_module_function(m, "run", atb_run, 1);
}
