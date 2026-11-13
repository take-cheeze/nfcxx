#include <ruby.h>

/* klass is a file-scope class variable. The parameter klass of dump_it shadows it: the parameter is
 * rewritten as an ordinary mrb_value (not wrapped as a class), in the header and in the body. */
static VALUE klass;

static VALUE dump_it(VALUE obj, VALUE klass, int depth) {
    if (klass == obj) return rb_str_new_cstr("same");
    if (depth > 0) return rb_str_new_cstr("deep");
    return rb_str_new_cstr("shallow");
}

static VALUE shadow_run(VALUE self, VALUE arg) {
    return dump_it(self, arg, 0);
}

void Init_shadow_param(void) {
    klass = rb_define_class("ShadowParam", rb_cObject);
    rb_define_method(klass, "run", shadow_run, 1);
}
