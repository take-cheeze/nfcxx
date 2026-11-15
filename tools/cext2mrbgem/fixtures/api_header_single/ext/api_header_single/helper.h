#include <ruby.h>
static VALUE hs_twice(VALUE self, VALUE x) {
    return rb_funcall(x, rb_intern("*"), 1, INT2FIX(2));
}
