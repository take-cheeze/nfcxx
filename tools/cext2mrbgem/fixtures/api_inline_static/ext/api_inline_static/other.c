#include <ruby.h>
inline static VALUE is_first(VALUE v) {
    return rb_funcall(v, rb_intern("inspect"), 0);
}
VALUE other_run(VALUE self, VALUE v) {
    return is_first(v);
}
