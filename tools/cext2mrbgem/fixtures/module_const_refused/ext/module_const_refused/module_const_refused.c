#include <ruby.h>

/* A local VALUE that is not assigned from rb_define_class or rb_define_module is not a tracked class variable,
   so both calls with it as the receiver stay refused. */
static VALUE mcr_run(VALUE self) {
    VALUE target = self;
    rb_define_const(target, "X", Qnil);
    rb_define_module_function(target, "y", mcr_run, 0);
    return Qnil;
}

void Init_module_const_refused(void) {
    rb_define_module("MCR");
}
