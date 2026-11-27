#include <ruby.h>

/* control: the inner call (rb_ensure, a refused form) is not rewritten, so the outer call stays refused too, with its
   own reason, and the output is marked not buildable */
static VALUE nar_concat(VALUE self, VALUE a) {
    return rb_str_concat(a, rb_ensure(NULL, Qnil, NULL, Qnil));
}

void Init_nested_args_refused(void) {
    VALUE m = rb_define_module("NestedArgsRefused");
    rb_define_method(m, "concat", nar_concat, 1);
}
