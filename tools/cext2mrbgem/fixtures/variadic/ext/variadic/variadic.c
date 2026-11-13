#include <ruby.h>

/* Variadic methods (argc -1): the converter reads argc and argv back through mrb_get_args("*"). */
static VALUE mVariadic;

static VALUE variadic_first(int argc, VALUE *argv, VALUE self) {
    if (argc == 0) return Qnil;
    return argv[0];
}

static VALUE variadic_count(int argc, VALUE *argv, VALUE self) {
    return INT2FIX(argc);
}

void Init_variadic(void) {
    mVariadic = rb_define_module("Variadic");
    rb_define_method(mVariadic, "first", variadic_first, -1);
    rb_define_singleton_method(mVariadic, "count", variadic_count, -1);
}
