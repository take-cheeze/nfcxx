#include <ruby.h>
static VALUE mBg;

static VALUE bg_has_block(VALUE self) {
    return rb_block_given_p() ? Qtrue : Qfalse;
}

void Init_api_block_given(void) {
    mBg = rb_define_module("BlockGiven");
    rb_define_module_function(mBg, "has_block", bg_has_block, 0);
}
