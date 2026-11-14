#include <ruby.h>

/* rb_yield in a registered method's body: the wrapper fetches the block; a yield in a helper is refused */
static VALUE mY;

static VALUE y_each_twice(VALUE self, VALUE v) {
    rb_yield(v);
    return rb_yield(v);
}

static VALUE y_nothing(VALUE self) {
    return Qnil;
}

void Init_api_yield(void) {
    mY = rb_define_module("YieldProbe");
    rb_define_module_function(mY, "twice", y_each_twice, 1);
    rb_define_module_function(mY, "nothing", y_nothing, 0);
}
