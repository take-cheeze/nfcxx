#include <ruby.h>

/* argc -2 takes the arguments as one Ruby array: not in the supported subset, so it stays refused. */
static VALUE mArr;

static VALUE arr_pair(VALUE self, VALUE args) {
    return args;
}

void Init_variadic_array(void) {
    mArr = rb_define_module("ArrayForm");
    rb_define_method(mArr, "pair", arr_pair, -2);
}
