#include <ruby.h>

/* A registered method whose impl needs the mruby state (it makes a String) and whose direct caller gets no mruby
   state: that caller's address is taken in a file-scope initializer, so it is not threaded. With the gem's Init the
   file-scope state is set for the life of the gem, so the caller passes it and the method is split. The caller's own
   table entry is still refused. */
static VALUE rsr_make(VALUE self, VALUE x) {
    return rb_str_new_cstr("make");
}

static VALUE rsr_plain_caller(VALUE x) {
    return rsr_make(x, x);
}

static VALUE (*rsr_fp)(VALUE) = rsr_plain_caller;

static VALUE rsr_method(VALUE self) {
    return rsr_fp(self);
}

void Init_reg_split_refused(void) {
    VALUE m = rb_define_module("RegSplitRefused");
    rb_define_method(m, "make", rsr_make, 1);
    rb_define_method(m, "call_plain", rsr_method, 0);
}
