#include <ruby.h>

/* rb_yield in a helper: the block is read from the calling method's frame (nfcx_block_arg), so it converts */
static VALUE yr_helper(VALUE v) {
    return rb_yield(v);
}

static VALUE yr_run(VALUE self, VALUE v) {
    return yr_helper(v);
}

/* rb_protect with rb_yield as the function: the block is yielded to with Qnil, as CRuby's rb_protect(rb_yield, Qnil, &state) */
static VALUE yr_protect(VALUE self) {
    int state;
    return rb_protect(rb_yield, Qnil, &state);
}

void Init_api_yield_refused(void) {
    VALUE m = rb_define_module("YieldRefused");
    rb_define_module_function(m, "run", yr_run, 1);
    rb_define_module_function(m, "protect", yr_protect, 0);
}
