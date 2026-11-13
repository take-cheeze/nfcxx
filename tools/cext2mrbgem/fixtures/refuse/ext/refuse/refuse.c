#include <ruby.h>

static VALUE body_fn(VALUE self) {
    return Qnil;
}

static VALUE cleanup_fn(VALUE self) {
    return Qnil;
}

static VALUE run_it(VALUE self, VALUE blk) {
    return rb_ensure(body_fn, self, cleanup_fn, self);
}

void Init_refuse(void) {
    VALUE mRefuse = rb_define_module("Refuse");
    rb_define_method(mRefuse, "run", run_it, 1);
}
