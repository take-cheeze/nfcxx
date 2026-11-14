#include <ruby.h>
static VALUE mEc;

static VALUE ec_body(VALUE data) {
    return rb_funcall(data, rb_intern("size"), 0);
}

static VALUE ec_ensure(VALUE data) {
    return Qnil;
}

static VALUE ec_run(VALUE self, VALUE arr) {
    return rb_ensure(ec_body, arr, ec_ensure, Qnil);
}

void Init_api_ensure_call(void) {
    mEc = rb_define_module("EnsureCall");
    rb_define_module_function(mEc, "run", ec_run, 1);
}
