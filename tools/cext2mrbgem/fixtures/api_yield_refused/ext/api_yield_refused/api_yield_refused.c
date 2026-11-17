#include <ruby.h>

/* rb_yield in a helper: the block is read from the calling method's frame (nfcx_block_arg), so it converts */
static VALUE yr_helper(VALUE v) {
    return rb_yield(v);
}

static VALUE yr_run(VALUE self, VALUE v) {
    return yr_helper(v);
}

void Init_api_yield_refused(void) {
    VALUE m = rb_define_module("YieldRefused");
    rb_define_module_function(m, "run", yr_run, 1);
}
